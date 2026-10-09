from __future__ import annotations

from typing import Any

from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Runlight's scheduled upkeep: rotates salts, sends due reports, applies retention, and builds rollups."

    def handle(self, *args: Any, **options: Any) -> None:
        from runlight import _js
        from runlight.django import runlight

        self.stdout.write(_js.dumps(runlight().check()))
