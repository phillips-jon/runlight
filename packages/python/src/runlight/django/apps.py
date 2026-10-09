from __future__ import annotations

from django.apps import AppConfig


class RunlightConfig(AppConfig):
    """Runlight's app: the runlight_check command."""

    name = "runlight.django"
    label = "runlight"
    verbose_name = "Runlight"
