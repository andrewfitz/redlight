import importlib.util
import pathlib
import unittest

HELPER = pathlib.Path(__file__).resolve().parents[1] / "generate-zone-coordinates.py"
spec = importlib.util.spec_from_file_location("generate_zone_coordinates", HELPER)
zones = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zones)

ZONE_TAB = """# comment
AD\t+4230+00131\tEurope/Andorra
AQ\t-7824+10654\tAntarctica/Vostok\tVostok
US\t+404251-0740023\tAmerica/New_York\tEastern (most areas)
IN\t+2232+08822\tAsia/Kolkata
short line
"""

TZDATA = """# version 2026f
Z America/New_York -4:56:2 - LMT 1883 N 18 17u
L America/New_York US/Eastern
L Asia/Kolkata Asia/Calcutta
L Asia/Calcutta Asia/Old_Calcutta
L Europe/Nowhere Europe/Lost
L Europe/Andorra Europe/Andorra
"""


class GenerateZoneCoordinatesTests(unittest.TestCase):
    def test_coordinates_with_and_without_seconds(self):
        self.assertEqual(zones.parse_coordinates("+4230+00131"), (42.5, 1 + 31 / 60))
        lat, lon = zones.parse_coordinates("+404251-0740023")
        self.assertAlmostEqual(lat, 40.714167, places=5)
        self.assertAlmostEqual(lon, -74.006389, places=5)
        self.assertEqual(zones.parse_coordinates("-7824+10654"), (-78.4, 106.9))
        for bad in ["", "4230+00131", "+42+001", "+4230"]:
            with self.assertRaises(ValueError):
                zones.parse_coordinates(bad)

    def test_zone_tab_rows(self):
        table = zones.parse_zone_tab(ZONE_TAB)
        self.assertEqual(sorted(table), ["America/New_York", "Antarctica/Vostok", "Asia/Kolkata", "Europe/Andorra"])
        self.assertEqual(table["Europe/Andorra"], (42.5, 1 + 31 / 60))

    def test_links_resolve_to_a_zone_with_a_city(self):
        table = zones.parse_zone_tab(ZONE_TAB)
        links = zones.parse_links(TZDATA, table)
        # A chain is followed; a link to nowhere and a zone's own name are left out.
        self.assertEqual(links, {
            "US/Eastern": "America/New_York",
            "Asia/Calcutta": "Asia/Kolkata",
            "Asia/Old_Calcutta": "Asia/Kolkata",
        })

    def test_render_writes_one_row_per_zone_and_link(self):
        table = zones.parse_zone_tab(ZONE_TAB)
        text = zones.render(table, zones.parse_links(TZDATA, table), "2026f")
        self.assertIn("tz database 2026f", text)
        self.assertIn("    Europe/Andorra 42.5 1.52\n", text)
        self.assertIn("    Antarctica/Vostok -78.4 106.9\n", text)
        self.assertIn("    US/Eastern America/New_York\n", text)
        self.assertIn("static let zoneCount = 4", text)
        self.assertIn("static let aliasCount = 3", text)
        self.assertEqual(zones.number(-0.001), "0")
        self.assertEqual(zones.number(10.0), "10")

    def test_the_checked_in_table_agrees_with_this_machines_tz_database(self):
        zoneinfo = zones.DEFAULT_ZONEINFO
        if not (zoneinfo / "zone.tab").exists():
            self.skipTest("no tz database here")
        table = zones.parse_zone_tab((zoneinfo / "zone.tab").read_text(encoding="utf-8"))
        checked_in = zones.OUTPUT.read_text(encoding="utf-8")
        # A newer tz database may add zones; every zone already in the file must still agree.
        for name, (lat, lon) in table.items():
            if f"    {name} " in checked_in:
                self.assertIn(f"    {name} {zones.number(lat)} {zones.number(lon)}\n", checked_in)


if __name__ == "__main__":
    unittest.main()
