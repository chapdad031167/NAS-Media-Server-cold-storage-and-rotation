"""Unit tests for torrent_cleanup_api.py.

No live network calls: the qBittorrent Web API layer is mocked
and library indexing runs against pytest tmp dirs.
"""

import urllib.error
from unittest import mock

import pytest

import torrent_cleanup_api as tca

MIN_RATIO = 1.0
MIN_SEED_SECS = 7 * 86400


def make_torrent(**overrides):
    """A finished, well-seeded, imported torrent -> removable."""
    torrent = {
        "name": "Heat.1995.1080p.BluRay.x264-GRP",
        "hash": "abc123",
        "progress": 1.0,
        "ratio": 2.0,
        "seeding_time": 0,
        "size": 4 * 1024 ** 3,
    }
    torrent.update(overrides)
    return torrent


LIBRARY = {"heat": "Heat (1995)", "the wire": "The Wire"}


def classify(torrent):
    return tca.classify_torrent(torrent, LIBRARY, MIN_RATIO, MIN_SEED_SECS)


# --- normalize parity with the shell scripts ---------------------------


class TestNormalize:
    @pytest.mark.parametrize(
        "name,expected",
        [
            ("Heat.1995.1080p.BluRay.x264-GRP", "heat"),
            ("Heat (1995)", "heat"),
            ("Show.Name.S01E05.720p.HDTV.x264-GRP", "show name"),
            ("Show.Name.S01.2160p.WEB-DL.DDP5.1-GRP", "show name"),
            ("Daily.Show.2026 06 27.1080p.WEB.h264-GRP", "daily show"),
            ("Some_Movie_2024_REMUX-GROUP", "some movie"),
            ("Movie.Title.2023.MULTI.1080p [tag]", "movie title"),
        ],
    )
    def test_release_names_reduce_to_titles(self, name, expected):
        assert tca.normalize(name) == expected


class TestLibraryIndex:
    def test_indexes_folders_across_dirs(self, tmp_path):
        movies = tmp_path / "Movies"
        tv = tmp_path / "TV"
        (movies / "Heat (1995)").mkdir(parents=True)
        (tv / "The Wire").mkdir(parents=True)
        (movies / "loose_file.mkv").write_text("x")  # files ignored

        index = tca.build_library_index(str(movies), str(tv))

        assert index == {"heat": "Heat (1995)", "the wire": "The Wire"}

    def test_missing_dir_is_skipped(self, tmp_path):
        index = tca.build_library_index(str(tmp_path / "nope"))
        assert index == {}


# --- classification -----------------------------------------------------


class TestClassifyTorrent:
    def test_incomplete_is_downloading(self):
        category, reason = classify(make_torrent(progress=0.42))
        assert category == "downloading"
        assert "42%" in reason

    def test_goal_not_met_keeps_seeding(self):
        # Ratio too low AND seed time too short -> never touched.
        # This is the H&R protection.
        category, reason = classify(
            make_torrent(ratio=0.5, seeding_time=1 * 86400)
        )
        assert category == "seeding"

    def test_ratio_goal_alone_is_enough(self):
        category, _ = classify(make_torrent(ratio=1.5, seeding_time=0))
        assert category == "removable"

    def test_seed_time_goal_alone_is_enough(self):
        category, _ = classify(make_torrent(ratio=0.1, seeding_time=8 * 86400))
        assert category == "removable"

    def test_goal_met_but_not_imported_is_kept(self):
        category, reason = classify(
            make_torrent(name="Unknown.Film.2024.1080p.WEB-GRP")
        )
        assert category == "unmatched"

    def test_removable_reports_the_library_match(self):
        category, reason = classify(make_torrent())
        assert category == "removable"
        assert "Heat (1995)" in reason


# --- qBittorrent API client (mocked, no network) ------------------------


def fake_response(body, set_cookie=""):
    r = mock.MagicMock()
    r.__enter__.return_value = r
    r.__exit__.return_value = False
    r.read.return_value = body.encode()
    r.headers = {"Set-Cookie": set_cookie} if set_cookie else {}
    return r


class TestQbtClient:
    def test_login_success_captures_session_cookie(self):
        client = tca.QbtClient("http://qbt:8080")
        resp = fake_response("Ok.", set_cookie="SID=tok123; path=/")
        with mock.patch.object(tca.urllib.request, "urlopen", return_value=resp) as m:
            assert client.login("admin", "pw") is True
        assert client.cookie == "SID=tok123"
        req = m.call_args[0][0]
        assert req.full_url == "http://qbt:8080/api/v2/auth/login"
        assert b"username=admin" in req.data

    def test_login_rejected_credentials(self):
        client = tca.QbtClient("http://qbt:8080")
        with mock.patch.object(
            tca.urllib.request, "urlopen", return_value=fake_response("Fails.")
        ):
            assert client.login("admin", "wrong") is False

    def test_login_unreachable(self):
        client = tca.QbtClient("http://qbt:8080")
        err = urllib.error.URLError("connection refused")
        with mock.patch.object(tca.urllib.request, "urlopen", side_effect=err):
            assert client.login("admin", "pw") is False

    def test_torrents_info_parses_json(self):
        client = tca.QbtClient("http://qbt:8080")
        with mock.patch.object(
            tca.urllib.request,
            "urlopen",
            return_value=fake_response('[{"name": "Heat"}]'),
        ):
            assert client.torrents_info() == [{"name": "Heat"}]

    def test_delete_posts_hash_and_deletefiles(self):
        client = tca.QbtClient("http://qbt:8080")
        client.cookie = "SID=tok123"
        with mock.patch.object(
            tca.urllib.request, "urlopen", return_value=fake_response("")
        ) as m:
            assert client.delete("abc123") is True
        req = m.call_args[0][0]
        assert req.full_url == "http://qbt:8080/api/v2/torrents/delete"
        assert b"hashes=abc123" in req.data
        assert b"deleteFiles=true" in req.data
        assert req.get_header("Cookie") == "SID=tok123"

    def test_delete_failure_returns_false(self):
        client = tca.QbtClient("http://qbt:8080")
        err = urllib.error.URLError("timeout")
        with mock.patch.object(tca.urllib.request, "urlopen", side_effect=err):
            assert client.delete("abc123") is False
