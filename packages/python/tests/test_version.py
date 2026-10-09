"""The versions and the icon are the TypeScript SDK's."""

from __future__ import annotations

from support import fixtures

from runlight import brand, version


def test_the_versions_and_icon_are_the_typescript_sdks() -> None:
    fixture = fixtures.load("version")
    assert version.VERSION == fixture["version"]
    assert version.API_VERSION == fixture["apiVersion"]
    assert brand.RUNLIGHT_ICON == fixture["icon"]
