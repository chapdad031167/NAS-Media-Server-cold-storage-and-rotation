"""Unit tests for cold_storage_scan.py decision rules.

No live network calls: the Radarr/Sonarr API layer is mocked and the
evaluation functions take an injectable path_exists so no real
filesystem layout is required either.
"""

import datetime
import io
import json
import os
import urllib.error
from unittest import mock

import pytest

import cold_storage_scan as scan

# Frozen clock so age calculations are deterministic
NOW = datetime.datetime(2026, 6, 1, tzinfo=datetime.timezone.utc)

CFG = dict(scan.DEFAULTS)
PATH_MAP = scan.build_path_map(CFG)

EXISTS = lambda p: True  # noqa: E731
MISSING = lambda p: False  # noqa: E731


def make_movie(**overrides):
    """A movie that passes every filter -> candidate."""
    movie = {
        "title": "Some Obscure Drama",
        "id": 42,
        "path": "/movies/Some Obscure Drama (2015)",
        "hasFile": True,
        "sizeOnDisk": 5 * 1024 ** 3,
        "digitalRelease": "2016-03-01T00:00:00Z",
    }
    movie.update(overrides)
    return movie


def make_series(**overrides):
    """A series that passes every filter -> candidate."""
    show = {
        "title": "Some Finished Drama",
        "id": 7,
        "path": "/tv/Some Finished Drama",
        "status": "ended",
        "lastAired": "2020-05-01T00:00:00Z",
        "statistics": {"sizeOnDisk": 30 * 1024 ** 3, "episodeFileCount": 20},
    }
    show.update(overrides)
    return show


def eval_movie(movie, path_exists=EXISTS):
    return scan.evaluate_movie(movie, CFG, PATH_MAP, now=NOW, path_exists=path_exists)


def eval_series(show, path_exists=EXISTS):
    return scan.evaluate_series(show, CFG, PATH_MAP, now=NOW, path_exists=path_exists)


# --- Kids-content hard exclusion (the critical safety rail) ---------


class TestKidsExclusion:
    def test_kids_movie_never_candidate(self):
        movie = make_movie(path="/kids/Some Cartoon (2010)")
        category, reason = eval_movie(movie)
        assert category == "kids"
        assert "never cold storage" in reason

    def test_kids_tv_never_candidate(self):
        show = make_series(path="/kidstv/Some Cartoon Show")
        category, reason = eval_series(show)
        assert category == "kids"
        assert "never cold storage" in reason

    def test_kids_exclusion_beats_every_other_rule(self):
        # Old, huge, unprotected, existing on disk - would be a prime
        # candidate anywhere else, but the kids root wins.
        movie = make_movie(
            path="/kids/Old Big Cartoon (1995)",
            sizeOnDisk=50 * 1024 ** 3,
            digitalRelease="1995-06-01T00:00:00Z",
        )
        assert eval_movie(movie)[0] == "kids"

    def test_kids_exclusion_checked_before_protected(self):
        # A protected franchise inside the kids root is reported as
        # kids, proving the kids check runs first.
        movie = make_movie(title="Batman: The Animated Movie", path="/kids/Batman (1993)")
        assert eval_movie(movie)[0] == "kids"

    def test_kids_match_is_root_prefix_only(self):
        # /kids/ must be the ROOT folder; a movie folder merely
        # containing the word 'kids' deeper in the path is fair game.
        movie = make_movie(path="/movies/Spy Kids Documentary (2005)")
        assert eval_movie(movie)[0] == "candidate"

    def test_kidstv_prefix_does_not_match_plain_tv_root(self):
        show = make_series(path="/tv/Kids These Days")
        category, _ = eval_series(show)
        assert category == "candidate"


# --- Protected franchise list ----------------------------------------


class TestProtectedFranchises:
    @pytest.mark.parametrize(
        "title",
        [
            "Star Wars: A New Hope (1977)",
            "The Dark Knight (2008)",
            "Halloween (1978)",
            "Halloween (2007)",  # same franchise, remake year - both protected
            "Godzilla vs. Kong",
            "Schitt's Creek",
        ],
    )
    def test_protected_titles(self, title):
        assert scan.is_protected(title) is True

    @pytest.mark.parametrize(
        "title",
        [
            "The Shawshank Redemption (1994)",
            "Star Search",  # shares a word with 'star wars' but not the phrase
            "Some Obscure Drama",
            "Knives Out (2019)",
        ],
    )
    def test_unprotected_titles(self, title):
        assert scan.is_protected(title) is False

    def test_protection_is_substring_based(self):
        # Documents intentional semantics: matching is substring, not
        # word-boundary, so 'saw' also shields 'The Sawmill'. The list
        # deliberately over-protects; false keeps are cheap, false
        # archives are not.
        assert scan.is_protected("The Sawmill") is True

    def test_protected_movie_skipped_despite_meeting_criteria(self):
        movie = make_movie(title="Halloween (1978)")
        category, reason = eval_movie(movie)
        assert category == "protected"
        assert "Halloween" in reason

    def test_protected_series_skipped(self):
        show = make_series(title="The Expanse")
        assert eval_series(show)[0] == "protected"


# --- TMDB release date fallback chain ---------------------------------


class TestReleaseDateFallback:
    def test_digital_release_preferred(self):
        movie = make_movie(
            digitalRelease="2025-06-01T00:00:00Z",  # 365 days before NOW
            physicalRelease="2010-01-01T00:00:00Z",
            inCinemas="2009-01-01T00:00:00Z",
        )
        assert scan.get_release_age_days(movie, NOW) == 365

    def test_falls_back_to_physical_release(self):
        movie = make_movie(
            physicalRelease="2024-06-01T00:00:00Z",
            inCinemas="2009-01-01T00:00:00Z",
        )
        del movie["digitalRelease"]
        assert scan.get_release_age_days(movie, NOW) == 730

    def test_falls_back_to_in_cinemas(self):
        movie = make_movie(inCinemas="2023-06-02T00:00:00Z")
        del movie["digitalRelease"]
        assert scan.get_release_age_days(movie, NOW) == 1095

    def test_falls_back_to_release_year(self):
        movie = make_movie(year=2020)
        del movie["digitalRelease"]
        # Year fallback anchors to Jan 1 of the release year
        expected = (NOW - datetime.datetime(2020, 1, 1, tzinfo=datetime.timezone.utc)).days
        assert scan.get_release_age_days(movie, NOW) == expected

    def test_no_date_at_all_means_age_zero(self):
        # Age 0 -> fails the age threshold -> never archived on
        # missing metadata. Fail-safe direction.
        movie = make_movie()
        del movie["digitalRelease"]
        assert scan.get_release_age_days(movie, NOW) == 0
        assert eval_movie(movie)[0] == "age"

    def test_unparseable_date_means_age_zero(self):
        assert scan.parse_added("not-a-date", NOW) == 0
        assert scan.parse_added("", NOW) == 0


# --- Size and age thresholds ------------------------------------------


class TestThresholds:
    def test_movie_under_2gb_skipped(self):
        movie = make_movie(sizeOnDisk=int(1.9 * 1024 ** 3))
        category, reason = eval_movie(movie)
        assert category == "size"

    def test_movie_at_exactly_2gb_passes_size_gate(self):
        movie = make_movie(sizeOnDisk=2 * 1024 ** 3)
        assert eval_movie(movie)[0] == "candidate"

    def test_movie_under_365_days_skipped(self):
        movie = make_movie(digitalRelease="2025-06-03T00:00:00Z")  # 363 days
        category, reason = eval_movie(movie)
        assert category == "age"
        assert "363d" in reason

    def test_movie_at_exactly_365_days_passes_age_gate(self):
        movie = make_movie(digitalRelease="2025-06-01T00:00:00Z")  # 365 days
        assert eval_movie(movie)[0] == "candidate"

    def test_thresholds_read_from_config(self):
        cfg = dict(CFG, MOVIE_MIN_SIZE_GB="10", MOVIE_MIN_AGE_DAYS="30")
        movie = make_movie(sizeOnDisk=5 * 1024 ** 3)
        category, _ = scan.evaluate_movie(movie, cfg, PATH_MAP, now=NOW, path_exists=EXISTS)
        assert category == "size"

    def test_tv_not_ended_skipped(self):
        show = make_series(status="continuing")
        category, reason = eval_series(show)
        assert category == "status"
        assert "continuing" in reason

    def test_tv_watchlist_only_skipped(self):
        show = make_series(statistics={"sizeOnDisk": 0, "episodeFileCount": 0})
        category, reason = eval_series(show)
        assert category == "status"
        assert "watchlist only" in reason

    def test_tv_recently_aired_skipped(self):
        show = make_series(lastAired="2026-01-01T00:00:00Z")
        assert eval_series(show)[0] == "age"

    def test_tv_ended_and_old_is_candidate(self):
        category, payload = eval_series(make_series())
        assert category == "candidate"
        assert payload["type"] == "tv"
        assert payload["id"] == 7
        assert payload["path"] == "/volume1/TV Shows/Some Finished Drama"


# --- Remaining gates ---------------------------------------------------


class TestOtherGates:
    def test_movie_without_file_skipped(self):
        movie = make_movie(hasFile=False)
        assert eval_movie(movie)[0] == "no_file"

    def test_movie_with_missing_host_path_skipped(self):
        category, reason = eval_movie(make_movie(), path_exists=MISSING)
        assert category == "not_found"
        assert "path not found" in reason

    def test_candidate_payload_has_translated_host_path_and_id(self):
        category, payload = eval_movie(make_movie())
        assert category == "candidate"
        assert payload["path"] == "/volume1/Movies/Some Obscure Drama (2015)"
        assert payload["id"] == 42
        assert payload["size_human"] == "5.0 GB"


# --- Path translation ---------------------------------------------------


class TestTranslatePath:
    def test_movie_prefix_translated(self):
        assert (
            scan.translate_path("/movies/Heat (1995)", PATH_MAP)
            == "/volume1/Movies/Heat (1995)"
        )

    def test_tv_prefix_translated(self):
        assert (
            scan.translate_path("/tv/The Wire", PATH_MAP)
            == "/volume1/TV Shows/The Wire"
        )

    def test_unknown_prefix_unchanged(self):
        assert scan.translate_path("/data/Heat (1995)", PATH_MAP) == "/data/Heat (1995)"


# --- Config loading ------------------------------------------------------


class TestConfig:
    def test_parse_config_file(self, tmp_path):
        cfg_file = tmp_path / "config.env"
        cfg_file.write_text(
            "# comment\n"
            "\n"
            'RADARR_API_KEY="abc123"\n'
            "MOVIE_MIN_SIZE_GB=4\n"
            "TV_DIR='/volume1/TV Shows'\n"
        )
        values = scan.parse_config_file(str(cfg_file))
        assert values == {
            "RADARR_API_KEY": "abc123",
            "MOVIE_MIN_SIZE_GB": "4",
            "TV_DIR": "/volume1/TV Shows",
        }

    def test_env_overrides_config_file(self, tmp_path):
        cfg_file = tmp_path / "config.env"
        cfg_file.write_text("MOVIE_MIN_SIZE_GB=4\nRADARR_URL=http://from-file:7878\n")
        cfg = scan.load_config(
            config_path=str(cfg_file),
            environ={"MOVIE_MIN_SIZE_GB": "8"},
        )
        assert cfg["MOVIE_MIN_SIZE_GB"] == "8"  # env wins
        assert cfg["RADARR_URL"] == "http://from-file:7878"  # file beats default
        assert cfg["TV_MIN_AGE_DAYS"] == "365"  # default survives

    def test_defaults_used_when_nothing_configured(self):
        cfg = scan.load_config(config_path="/nonexistent/config.env", environ={})
        assert cfg["MOVIE_MIN_SIZE_GB"] == "2"
        assert cfg["RADARR_API_KEY"] == ""


# --- Stage 1 additions ----------------------------------------------------


class TestProtectedListFile:
    def test_load_protected_from_file(self, tmp_path):
        f = tmp_path / "protected.txt"
        f.write_text("# my list\n\nstar wars\nMy Custom Franchise\n")
        assert scan.load_protected(str(f)) == ["star wars", "my custom franchise"]

    def test_missing_file_falls_back_to_builtin(self):
        assert scan.load_protected("/nonexistent/protected.txt") == scan.PROTECTED

    def test_empty_file_falls_back_to_builtin(self, tmp_path):
        f = tmp_path / "protected.txt"
        f.write_text("# only comments\n\n")
        assert scan.load_protected(str(f)) == scan.PROTECTED

    def test_repo_file_matches_builtin_list(self):
        # The shipped protected_franchises.txt is the same list as
        # the built-in fallback - they must not drift apart.
        repo_file = scan.DEFAULTS["PROTECTED_LIST_FILE"]
        assert scan.load_protected(repo_file) == scan.PROTECTED

    def test_custom_list_threads_through_evaluation(self):
        movie = make_movie(title="My Custom Franchise: The Reckoning")
        assert eval_movie(movie)[0] == "candidate"  # not protected by default
        category, _ = scan.evaluate_movie(
            movie, CFG, PATH_MAP, now=NOW, path_exists=EXISTS,
            protected=["my custom franchise"],
        )
        assert category == "protected"


class TestLogPruning:
    def test_prunes_only_old_log_files(self, tmp_path):
        now = 2_000_000_000
        old_log = tmp_path / "run_old.log"
        new_log = tmp_path / "run_new.log"
        old_txt = tmp_path / "notes.txt"
        for p in (old_log, new_log, old_txt):
            p.write_text("x")
        os.utime(old_log, (now - 100 * 86400, now - 100 * 86400))
        os.utime(old_txt, (now - 100 * 86400, now - 100 * 86400))
        os.utime(new_log, (now - 86400, now - 86400))

        removed = scan.prune_old_logs(str(tmp_path), 90, now=now)

        assert removed == 1
        assert not old_log.exists()
        assert new_log.exists()
        assert old_txt.exists()  # only *.log files are pruned

    def test_missing_dir_is_a_noop(self):
        assert scan.prune_old_logs("/nonexistent/logs", 90, now=2_000_000_000) == 0


class TestLocking:
    def test_second_lock_refused_then_released(self, tmp_path):
        lock_path = str(tmp_path / "scan.lock")
        first = scan.acquire_lock(lock_path)
        with pytest.raises(SystemExit):
            scan.acquire_lock(lock_path)
        first.close()
        second = scan.acquire_lock(lock_path)  # released -> reusable
        second.close()


# --- API layer (mocked, no network) --------------------------------------


class TestApiGet:
    def test_api_get_parses_json_and_sends_key(self):
        body = json.dumps([{"title": "Heat"}]).encode()
        fake = mock.MagicMock()
        fake.__enter__.return_value = io.BytesIO(body)
        with mock.patch.object(scan.urllib.request, "urlopen", return_value=fake) as m:
            result = scan.api_get("http://radarr:7878", "sekret", "movie")
        assert result == [{"title": "Heat"}]
        req = m.call_args[0][0]
        assert req.full_url == "http://radarr:7878/api/v3/movie"
        assert req.get_header("X-api-key") == "sekret"

    def test_api_get_returns_none_on_network_error(self):
        err = urllib.error.URLError("connection refused")
        with mock.patch.object(scan.urllib.request, "urlopen", side_effect=err):
            assert scan.api_get("http://radarr:7878", "sekret", "movie") is None


class TestWatchedGuard:
    """v2.4: Tautulli last-played guard. Missing index (Tautulli
    unconfigured/unreachable) must behave exactly like pre-v2.4."""

    def _index(self, movie_days_ago=None, tv_days_ago=None):
        idx = {"movie": {}, "tv": {}}
        if movie_days_ago is not None:
            idx["movie"][("some obscure drama", 0)] = (
                NOW.timestamp() - movie_days_ago * 86400
            )
        if tv_days_ago is not None:
            idx["tv"]["some finished drama"] = NOW.timestamp() - tv_days_ago * 86400
        return idx

    def test_recently_watched_movie_skipped(self):
        category, reason = scan.evaluate_movie(
            make_movie(), CFG, PATH_MAP, now=NOW, path_exists=EXISTS,
            watch_index=self._index(movie_days_ago=30),
        )
        assert category == "watched"
        assert "played 30d ago" in reason

    def test_long_unwatched_movie_still_candidate(self):
        category, _ = scan.evaluate_movie(
            make_movie(), CFG, PATH_MAP, now=NOW, path_exists=EXISTS,
            watch_index=self._index(movie_days_ago=400),
        )
        assert category == "candidate"

    def test_never_watched_movie_still_candidate(self):
        category, _ = scan.evaluate_movie(
            make_movie(), CFG, PATH_MAP, now=NOW, path_exists=EXISTS,
            watch_index={"movie": {}, "tv": {}},
        )
        assert category == "candidate"

    def test_no_index_means_guard_disabled(self):
        assert eval_movie(make_movie())[0] == "candidate"

    def test_recently_watched_series_skipped(self):
        category, _ = scan.evaluate_series(
            make_series(), CFG, PATH_MAP, now=NOW, path_exists=EXISTS,
            watch_index=self._index(tv_days_ago=10),
        )
        assert category == "watched"

    def test_guard_days_configurable(self):
        cfg = dict(CFG, WATCHED_GUARD_DAYS="20")
        category, _ = scan.evaluate_movie(
            make_movie(), cfg, PATH_MAP, now=NOW, path_exists=EXISTS,
            watch_index=self._index(movie_days_ago=30),
        )
        assert category == "candidate"  # 30d ago is outside a 20d guard

    def test_kids_and_protected_still_win_over_watch_history(self):
        # The guard only ever REMOVES candidates; an unwatched kids
        # or protected item is still excluded.
        movie = make_movie(path="/kids/Some Cartoon (2010)")
        category, _ = scan.evaluate_movie(
            movie, CFG, PATH_MAP, now=NOW, path_exists=EXISTS,
            watch_index={"movie": {}, "tv": {}},
        )
        assert category == "kids"

    def test_last_played_days_math(self):
        idx = self._index(movie_days_ago=45)
        assert scan.last_played_days(idx, "movie", "Some Obscure Drama", 0, NOW) == 45
        assert scan.last_played_days(idx, "movie", "Unknown Movie", 0, NOW) is None
        assert scan.last_played_days(None, "movie", "Anything", 0, NOW) is None


class TestTautulliApi:
    def test_success_returns_data(self):
        cfg = {"TAUTULLI_URL": "http://tautulli:8181", "TAUTULLI_API_KEY": "tkey"}
        body = json.dumps(
            {"response": {"result": "success", "data": [{"section_id": 1}]}}
        ).encode()
        fake = mock.MagicMock()
        fake.__enter__.return_value = io.BytesIO(body)
        with mock.patch.object(scan.urllib.request, "urlopen", return_value=fake) as m:
            data = scan.tautulli_api(cfg, "get_libraries")
        assert data == [{"section_id": 1}]
        url = m.call_args[0][0]
        assert url.startswith("http://tautulli:8181/api/v2?")
        assert "apikey=tkey" in url and "cmd=get_libraries" in url

    def test_error_result_returns_none(self):
        cfg = {"TAUTULLI_URL": "http://tautulli:8181", "TAUTULLI_API_KEY": "tkey"}
        body = json.dumps({"response": {"result": "error"}}).encode()
        fake = mock.MagicMock()
        fake.__enter__.return_value = io.BytesIO(body)
        with mock.patch.object(scan.urllib.request, "urlopen", return_value=fake):
            assert scan.tautulli_api(cfg, "get_libraries") is None

    def test_network_failure_returns_none(self):
        cfg = {"TAUTULLI_URL": "http://tautulli:8181", "TAUTULLI_API_KEY": "tkey"}
        err = urllib.error.URLError("no route")
        with mock.patch.object(scan.urllib.request, "urlopen", side_effect=err):
            assert scan.tautulli_api(cfg, "get_libraries") is None


class TestFetchWatchIndex:
    CFG_T = {"TAUTULLI_URL": "http://t:8181", "TAUTULLI_API_KEY": "k"}

    def test_builds_movie_and_tv_indexes(self):
        def fake_api(cfg, cmd, **params):
            if cmd == "get_libraries":
                return [
                    {"section_id": 1, "section_type": "movie"},
                    {"section_id": 2, "section_type": "show"},
                    {"section_id": 3, "section_type": "artist"},  # ignored
                ]
            if params.get("section_id") == 1:
                return {"data": [
                    {"title": "Heat", "year": 1995, "last_played": 1000},
                    {"title": "Never Played", "year": 2000, "last_played": None},
                ]}
            return {"data": [{"title": "The Wire", "last_played": 2000}]}

        with mock.patch.object(scan, "tautulli_api", side_effect=fake_api):
            index = scan.fetch_watch_index(self.CFG_T)

        assert index == {"movie": {("heat", 1995): 1000}, "tv": {"the wire": 2000}}

    def test_unreachable_tautulli_returns_none(self):
        with mock.patch.object(scan, "tautulli_api", return_value=None):
            assert scan.fetch_watch_index(self.CFG_T) is None


class TestNotify:
    def test_noop_when_unconfigured(self):
        with mock.patch.object(scan.urllib.request, "urlopen") as m:
            scan.notify({"NTFY_URL": "", "DISCORD_WEBHOOK_URL": ""}, "hello")
        m.assert_not_called()

    def test_posts_to_ntfy_and_discord(self):
        cfg = {
            "NTFY_URL": "https://ntfy.example/topic",
            "DISCORD_WEBHOOK_URL": "https://discord.example/hook",
        }
        with mock.patch.object(scan.urllib.request, "urlopen") as m:
            m.return_value.__enter__ = lambda s: s
            m.return_value.__exit__ = lambda s, *a: False
            scan.notify(cfg, "3 candidates ready")
        assert m.call_count == 2
        ntfy_req, discord_req = m.call_args_list[0][0][0], m.call_args_list[1][0][0]
        assert ntfy_req.full_url == "https://ntfy.example/topic"
        assert ntfy_req.data == b"3 candidates ready"
        assert json.loads(discord_req.data.decode()) == {"content": "3 candidates ready"}

    def test_failed_push_never_raises(self):
        cfg = {"NTFY_URL": "https://ntfy.example/topic", "DISCORD_WEBHOOK_URL": ""}
        err = urllib.error.URLError("no route to host")
        with mock.patch.object(scan.urllib.request, "urlopen", side_effect=err):
            scan.notify(cfg, "hello")  # must not raise


# --- End-to-end scan over mocked API data ---------------------------------


class TestScanIntegration:
    def test_scan_movies_buckets(self):
        data = [
            make_movie(),                                             # candidate
            make_movie(title="Frozen Sing-Along", path="/kids/Frozen"),  # kids
            make_movie(title="Halloween (1978)"),                     # protected
            make_movie(sizeOnDisk=1024 ** 3),                         # too small
            make_movie(digitalRelease="2026-05-01T00:00:00Z"),        # too new
            make_movie(hasFile=False),                                # no file
        ]
        buckets = scan.scan_movies(data, CFG, PATH_MAP, now=NOW, path_exists=EXISTS)
        assert len(buckets["candidate"]) == 1
        assert len(buckets["kids"]) == 1
        assert len(buckets["protected"]) == 1
        assert len(buckets["size"]) == 1
        assert len(buckets["age"]) == 1
        assert len(buckets["no_file"]) == 1

    def test_scan_series_buckets(self):
        data = [
            make_series(),                                    # candidate
            make_series(path="/kidstv/Bluey"),                # kids
            make_series(title="The Expanse"),                 # protected
            make_series(status="continuing"),                 # not ended
            make_series(lastAired="2026-05-01T00:00:00Z"),    # too recent
        ]
        buckets = scan.scan_series(data, CFG, PATH_MAP, now=NOW, path_exists=EXISTS)
        assert len(buckets["candidate"]) == 1
        assert len(buckets["kids"]) == 1
        assert len(buckets["protected"]) == 1
        assert len(buckets["status"]) == 1
        assert len(buckets["age"]) == 1
