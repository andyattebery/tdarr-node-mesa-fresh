#!/usr/bin/env python3
"""refresh-channels.py and refresh-base.py -- 40 cases (27 die sites, 13 behavioural).

Run via ./tests/run.sh, or directly:  python3 -m unittest discover -s tests -p 'test_*.py'

No network. Every request is stubbed by patching urllib.request.urlopen, which is the single
choke point both scripts funnel through. Nothing here needs the scripts to be modified for
testability -- the hooks (--file, the LP module global) already existed.

Two things worth knowing before editing this file:

  * The scripts have hyphens in their names, so they cannot be imported normally. load()
    below uses importlib, which is the only reason this is not a plain `import`.
  * refresh-channels.py's SERIES is computed at IMPORT time from LP, so patching LP later
    does not change it. That is harmless -- SERIES is only ever a query parameter, never a
    URL that gets fetched -- but a test that assumes otherwise will not do what it looks like.
"""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import tempfile
import unittest
import urllib.error
import urllib.request
from unittest import mock

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(REPO, "tests", "fixtures")


def load(filename, name):
    path = os.path.join(REPO, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


rc = load("refresh-channels.py", "refresh_channels")
rb = load("refresh-base.py", "refresh_base")
# Retries must not actually sleep; the retry COUNT is what these tests care about.
rc.BACKOFF = 0
rb.BACKOFF = 0

DIGEST_A = "sha256:" + "a" * 58 + "aaaaaa"
DIGEST_B = "sha256:" + "b" * 58 + "bbbbbb"


class Resp(io.BytesIO):
    """Enough of an http.client.HTTPResponse for these scripts."""

    def __init__(self, body=b"", headers=None):
        super().__init__(body)
        self.headers = headers or {}

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def http_error(code):
    return urllib.error.HTTPError("http://x", code, f"HTTP {code}", {}, None)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def quiet(fn, *a, **kw):
    """Run fn, swallowing its stderr report, returning (result_or_None, systemexit_or_None)."""
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            return fn(*a, **kw), None
    except SystemExit as exc:
        return None, exc


class Tmp(unittest.TestCase):
    """Gives each test a private copy of a fixture it may rewrite."""

    def copy(self, fixture):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        dst = os.path.join(d, os.path.basename(fixture))
        shutil.copy(os.path.join(FIXTURES, fixture), dst)
        return dst

    def assertDies(self, fn, *a, **kw):
        _, exc = quiet(fn, *a, **kw)
        self.assertIsNotNone(exc, "expected the script to die, it returned normally")
        self.assertEqual(exc.code, 1)


# ---------------------------------------------------------------- refresh-channels.py

class TestRefreshChannelsParse(Tmp):
    def test_L134_field_count(self):
        self.assertDies(rc.parse, os.path.join(FIXTURES, "channels-two-fields.txt"))

    def test_L134_too_many_fields(self):
        self.assertDies(rc.parse, os.path.join(FIXTURES, "channels-five-fields.txt"))

    def test_L139_field4_not_hold(self):
        self.assertDies(rc.parse, os.path.join(FIXTURES, "channels-bad-hold.txt"))

    def test_L144_no_channels(self):
        self.assertDies(rc.parse, os.path.join(FIXTURES, "channels-empty.txt"))

    def test_L148_duplicate_channel(self):
        self.assertDies(rc.parse, os.path.join(FIXTURES, "channels-dup.txt"))

    def test_good_file_parses(self):
        _, rows = rc.parse(os.path.join(FIXTURES, "channels-good.txt"))
        self.assertEqual([r[1] for r in rows], ["kisak", "mesarc"])


class TestRefreshChannelsApiPath(Tmp):
    def test_L66_not_a_ppa_reference(self):
        self.assertDies(rc.api_path, "kisak/kisak-mesa")

    def test_L69_unparseable_ppa(self):
        self.assertDies(rc.api_path, "ppa:kisak")

    def test_valid_ppa(self):
        self.assertEqual(
            rc.api_path("ppa:kisak/kisak-mesa"),
            "https://api.launchpad.net/1.0/~kisak/+archive/ubuntu/kisak-mesa",
        )


class TestRefreshChannelsRetry(Tmp):
    def test_5xx_is_retried(self):
        calls = []

        def boom(url, timeout=None):
            calls.append(url)
            raise http_error(503)

        with mock.patch.object(urllib.request, "urlopen", boom):
            self.assertDies(rc.get_json, "http://x", "stub")
        self.assertEqual(len(calls), rc.RETRIES, "5xx should be retried up to RETRIES")

    def test_4xx_is_not_retried(self):
        calls = []

        def boom(url, timeout=None):
            calls.append(url)
            raise http_error(404)

        with mock.patch.object(urllib.request, "urlopen", boom):
            self.assertDies(rc.get_json, "http://x", "stub")
        self.assertEqual(len(calls), 1, "a 4xx is a real answer and must not be retried")

    def test_transport_error_is_retried(self):
        calls = []

        def boom(url, timeout=None):
            calls.append(url)
            raise urllib.error.URLError("refused")

        with mock.patch.object(urllib.request, "urlopen", boom):
            self.assertDies(rc.get_json, "http://x", "stub")
        self.assertEqual(len(calls), rc.RETRIES)


class TestRefreshChannelsPublished(Tmp):
    def stub(self, versions):
        body = json.dumps({"entries": [{"binary_package_version": v} for v in versions]}).encode()
        return lambda url, timeout=None: Resp(body)

    def test_L107_not_exactly_one_entry(self):
        with mock.patch.object(urllib.request, "urlopen", self.stub(["a~kisak1", "b~kisak1"])):
            self.assertDies(rc.published_version, "ppa:kisak/kisak-mesa", "kisak")

    def test_L107_zero_entries(self):
        with mock.patch.object(urllib.request, "urlopen", self.stub([])):
            self.assertDies(rc.published_version, "ppa:kisak/kisak-mesa", "kisak")

    def test_L117_version_lacks_channel_name(self):
        with mock.patch.object(urllib.request, "urlopen", self.stub(["26.2.2~mesarc0~n"])):
            self.assertDies(rc.published_version, "ppa:kisak/kisak-mesa", "kisak")

    def test_valid(self):
        with mock.patch.object(urllib.request, "urlopen", self.stub(["26.2.9~kisak1~n"])):
            got, _ = quiet(rc.published_version, "ppa:kisak/kisak-mesa", "kisak")
        self.assertEqual(got, "26.2.9~kisak1~n")


class TestRefreshChannelsMain(Tmp):
    def run_main(self, path, mode, versions):
        body = json.dumps({"entries": [{"binary_package_version": versions}]}).encode()
        argv = ["refresh-channels.py", mode, "--file", path]
        with mock.patch.object(urllib.request, "urlopen", lambda u, timeout=None: Resp(body)), \
                mock.patch("sys.argv", argv):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rv, exc = quiet(rc.main)
            return (rv if exc is None else exc.code), out.getvalue()

    def test_held_row_is_left_alone(self):
        path = self.copy("channels-held.txt")
        before = read(path)
        rv, out = self.run_main(path, "--write", "99.9.9~kisak1~n")
        self.assertEqual(rv, 0)
        # Contrast with refresh-base.py, whose --write prints an empty string when nothing
        # moved. This script's stdout contract is "always a JSON array".
        self.assertEqual(out.strip(), "[]", "a held row yields an empty array, not no output")
        self.assertEqual(read(path), before, "a held row must not be rewritten")

    def test_up_to_date_leaves_file_byte_identical(self):
        path = self.copy("channels-held.txt")  # single row, unheld copy made below
        write(path, "kisak      ppa:kisak/kisak-mesa   26.2.2~kisak1~n\n")
        before = read(path)
        rv, out = self.run_main(path, "--write", "26.2.2~kisak1~n")
        self.assertEqual(rv, 0)
        self.assertEqual(out.strip(), "[]")
        self.assertEqual(read(path), before)

    def test_changed_row_rewritten_with_alignment(self):
        path = self.copy("channels-held.txt")
        write(path, "kisak      ppa:kisak/kisak-mesa   26.2.2~kisak1~n\n")
        rv, out = self.run_main(path, "--write", "26.3.0~kisak1~n")
        self.assertEqual(rv, 0)
        self.assertEqual(json.loads(out), ["kisak"], "the changed channel is named on stdout")
        self.assertEqual(
            read(path),
            "kisak      ppa:kisak/kisak-mesa   26.3.0~kisak1~n\n",
            "the row keeps its column alignment",
        )

    def test_check_exits_1_when_behind(self):
        path = self.copy("channels-held.txt")
        write(path, "kisak      ppa:kisak/kisak-mesa   26.2.2~kisak1~n\n")
        rv, _ = self.run_main(path, "--check", "26.3.0~kisak1~n")
        self.assertEqual(rv, 1)
        self.assertEqual(
            read(path),
            "kisak      ppa:kisak/kisak-mesa   26.2.2~kisak1~n\n",
            "--check must not write",
        )

    def test_check_exits_0_when_current(self):
        path = self.copy("channels-held.txt")
        write(path, "kisak      ppa:kisak/kisak-mesa   26.2.2~kisak1~n\n")
        rv, _ = self.run_main(path, "--check", "26.2.2~kisak1~n")
        self.assertEqual(rv, 0)


# -------------------------------------------------------------------- refresh-base.py

def index(entries):
    return json.dumps({"manifests": entries}).encode()


REAL_INDEX = index([
    {"digest": "sha256:amd", "platform": {"architecture": "amd64", "os": "linux"}},
    {"digest": "sha256:att1", "platform": {"architecture": "unknown", "os": "unknown"}},
    {"digest": "sha256:arm", "platform": {"architecture": "arm64", "os": "linux"}},
    {"digest": "sha256:att2", "platform": {"architecture": "unknown", "os": "unknown"}},
])


class BaseStub:
    """Dispatches urlopen by URL, imitating GHCR closely enough for refresh-base.py."""

    def __init__(self, latest=DIGEST_B, label="dev_2.87.01_2026_09_01T00_00_00z",
                 tag_digest=None, idx=REAL_INDEX, manifest_body=None, blob_body=None,
                 tag_missing=False):
        self.latest = latest
        self.label = label
        self.tag_digest = tag_digest if tag_digest is not None else latest
        self.idx = idx
        self.manifest_body = manifest_body
        self.blob_body = blob_body
        self.tag_missing = tag_missing

    def __call__(self, req, timeout=None):
        url = req.full_url if hasattr(req, "full_url") else req
        method = req.get_method() if hasattr(req, "get_method") else "GET"
        if "/token?" in url:
            return Resp(json.dumps({"token": "stub"}).encode())
        if method == "HEAD":
            ref = url.rsplit("/manifests/", 1)[1]
            if ref == "latest":
                if self.latest is None:
                    raise http_error(404)
                return Resp(headers={"Docker-Content-Digest": self.latest})
            if self.tag_missing:
                raise http_error(404)
            return Resp(headers={"Docker-Content-Digest": self.tag_digest})
        if "/blobs/" in url:
            if self.blob_body is not None:
                return Resp(self.blob_body)
            return Resp(json.dumps(
                {"config": {"Labels": {"org.opencontainers.image.version": self.label}}}
                if self.label is not None else {"config": {"Labels": {}}}).encode())
        # GET on a manifest: the index first, then the amd64 manifest.
        if url.endswith("/manifests/" + self.latest):
            return Resp(self.idx)
        if self.manifest_body is not None:
            return Resp(self.manifest_body)
        return Resp(json.dumps({"config": {"digest": "sha256:cfg"}}).encode())


class TestRefreshBaseParse(Tmp):
    def test_L97_field_count(self):
        self.assertDies(rb.parse, os.path.join(FIXTURES, "base-two-fields.txt"))

    def test_L102_field4_not_hold(self):
        self.assertDies(rb.parse, os.path.join(FIXTURES, "base-bad-hold.txt"))

    def test_L109_not_exactly_one_row(self):
        self.assertDies(rb.parse, os.path.join(FIXTURES, "base-two-rows.txt"))

    def test_L109_zero_rows(self):
        self.assertDies(rb.parse, os.path.join(FIXTURES, "base-empty.txt"))

    def test_L113_bad_digest(self):
        self.assertDies(rb.parse, os.path.join(FIXTURES, "base-short-digest.txt"))


class TestRefreshBaseRegistry(Tmp):
    def test_L125_not_ghcr(self):
        self.assertDies(rb.Registry, "docker.io/x/y")

    def test_L127_unparseable_image(self):
        self.assertDies(rb.Registry, "ghcr.io")

    def test_L165_token_reply_has_no_token(self):
        stub = lambda req, timeout=None: Resp(json.dumps({"errors": []}).encode())
        with mock.patch.object(urllib.request, "urlopen", stub):
            self.assertDies(rb.Registry, "ghcr.io/x/y")

    def test_L189_unparseable_manifest_json(self):
        with mock.patch.object(urllib.request, "urlopen", BaseStub(manifest_body=b"not json")):
            reg, _ = quiet(rb.Registry, "ghcr.io/x/y")
            self.assertDies(reg.json_at, "sha256:whatever")

    def test_L197_unparseable_blob_json(self):
        with mock.patch.object(urllib.request, "urlopen", BaseStub(blob_body=b"not json")):
            reg, _ = quiet(rb.Registry, "ghcr.io/x/y")
            self.assertDies(reg.blob, "sha256:cfg")

    def test_404_with_allow_404_returns_none(self):
        with mock.patch.object(urllib.request, "urlopen", BaseStub(tag_missing=True)):
            reg, _ = quiet(rb.Registry, "ghcr.io/x/y")
            got, _ = quiet(reg.digest_of, "nosuchtag")
        self.assertIsNone(got, "a missing tag is a fact, not a failure")

    def test_5xx_is_retried(self):
        calls = []

        def boom(req, timeout=None):
            calls.append(req)
            if "/token?" in (req.full_url if hasattr(req, "full_url") else req):
                return Resp(json.dumps({"token": "t"}).encode())
            raise http_error(502)

        with mock.patch.object(urllib.request, "urlopen", boom):
            reg, _ = quiet(rb.Registry, "ghcr.io/x/y")
            self.assertDies(reg.digest_of, "sometag")
        self.assertEqual(len(calls) - 1, rb.RETRIES, "5xx retried up to RETRIES")

    def test_4xx_is_not_retried(self):
        calls = []

        def boom(req, timeout=None):
            calls.append(req)
            if "/token?" in (req.full_url if hasattr(req, "full_url") else req):
                return Resp(json.dumps({"token": "t"}).encode())
            raise http_error(401)

        with mock.patch.object(urllib.request, "urlopen", boom):
            reg, _ = quiet(rb.Registry, "ghcr.io/x/y")
            self.assertDies(reg.digest_of, "sometag")
        self.assertEqual(len(calls) - 1, 1, "a 401 is a real answer and must not be retried")


class TestRefreshBaseVersionOf(Tmp):
    def version_of(self, stub):
        with mock.patch.object(urllib.request, "urlopen", stub):
            reg, _ = quiet(rb.Registry, "ghcr.io/x/y")
            return quiet(rb.version_of, reg, stub.latest)

    def test_real_index_shape_picks_amd64(self):
        got, exc = self.version_of(BaseStub())
        self.assertIsNone(exc)
        self.assertEqual(got, "2.87.01",
                         "the two unknown/unknown attestation manifests must be ignored")

    def test_L215_two_amd64_entries(self):
        idx = index([
            {"digest": "sha256:a1", "platform": {"architecture": "amd64", "os": "linux"}},
            {"digest": "sha256:a2", "platform": {"architecture": "amd64", "os": "linux"}},
        ])
        _, exc = self.version_of(BaseStub(idx=idx))
        self.assertIsNotNone(exc)

    def test_L215_no_amd64_entry(self):
        idx = index([{"digest": "sha256:arm", "platform": {"architecture": "arm64", "os": "linux"}}])
        _, exc = self.version_of(BaseStub(idx=idx))
        self.assertIsNotNone(exc)

    def test_L223_no_version_label_at_all(self):
        _, exc = self.version_of(BaseStub(label=None))
        self.assertIsNotNone(exc)

    def test_L227_label_without_x_y_z(self):
        _, exc = self.version_of(BaseStub(label="dev_nightly_build"))
        self.assertIsNotNone(exc)

    def test_L233_named_tag_missing_upstream(self):
        _, exc = self.version_of(BaseStub(tag_missing=True))
        self.assertIsNotNone(exc)

    def test_L235_named_tag_resolves_elsewhere(self):
        _, exc = self.version_of(BaseStub(tag_digest=DIGEST_A))
        self.assertIsNotNone(exc, "a tag pointing at another digest must not be trusted")


class TestRefreshBaseMain(Tmp):
    def run_main(self, path, mode, stub):
        argv = ["refresh-base.py", mode, "--file", path]
        with mock.patch.object(urllib.request, "urlopen", stub), mock.patch("sys.argv", argv):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rv, exc = quiet(rb.main)
            return (rv if exc is None else exc.code), out.getvalue()

    def test_held_row_left_alone(self):
        path = self.copy("base-held.txt")
        before = read(path)
        rv, out = self.run_main(path, "--write", BaseStub())
        self.assertEqual(rv, 0)
        self.assertEqual(out.strip(), "")
        self.assertEqual(read(path), before)

    def test_L259_latest_does_not_exist(self):
        path = self.copy("base-good.txt")
        rv, _ = self.run_main(path, "--check", BaseStub(latest=None))
        self.assertEqual(rv, 1)

    def test_unchanged_prints_nothing(self):
        path = self.copy("base-good.txt")
        pinned = read(path).split()[2]
        before = read(path)
        rv, out = self.run_main(path, "--write", BaseStub(latest=pinned))
        self.assertEqual(rv, 0)
        self.assertEqual(out.strip(), "")
        self.assertEqual(read(path), before)

    def test_changed_rewrites_row_and_keeps_alignment(self):
        path = self.copy("base-good.txt")
        rv, out = self.run_main(path, "--write", BaseStub())
        self.assertEqual(rv, 0)
        self.assertEqual(out.strip(), "2.87.01")
        self.assertEqual(
            read(path).strip().splitlines()[-1],
            rb.ROW_FMT % ("ghcr.io/haveagitgat/tdarr_node", "2.87.01", DIGEST_B),
            "the rewritten row matches ROW_FMT exactly",
        )

    def test_check_does_not_write(self):
        path = self.copy("base-good.txt")
        before = read(path)
        rv, _ = self.run_main(path, "--check", BaseStub())
        self.assertEqual(rv, 1)
        self.assertEqual(read(path), before)


if __name__ == "__main__":
    unittest.main(verbosity=1)
