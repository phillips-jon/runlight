# frozen_string_literal: true

module Runlight
  module Importers
    # One shortener. `step` does a bounded slice of work (a few links) and hands
    # back a cursor, so imports run in small requests that fit any host's time
    # limit and can show progress. Credentials come with every step and are
    # never stored.
    #
    # The shapes are TS's, as Hashes with the same keys:
    # - ForeignLink: `sourceId` (the other service's id, so a re-run recognises the link), `slug`, `domain`
    #   (the short link's domain there; shortener-owned domains such as bit.ly and dub.sh are not kept),
    #   `name`, `url`, `createdAt` (ms).
    # - ForeignClick: `ts` (ms), and whichever of `visit` (groups clicks into one visit), `referrer`, `path`,
    #   `query` (path and query of the short URL as clicked, for campaign tags), `country`, `region`, `city`,
    #   `browser`, `os`, `device`, `screen`, and `language` the service knows. A field it does not know is left out.
    # - DailyClicks: `day` (YYYY-MM-DD, UTC) and `clicks`, for services that only keep counts.
    # - ImportStep: `cursor`, `done`, `total`, `links`, `clicks`, `skipped`, `failed`.
    #
    # `step(credentials, cursor, known)` returns `{ "cursor", "total", "links" }`, each link being
    # `{ "link", "clicks"?, "daily"?, "known"? }`. `known` is a callable (source_id, slug = nil, url = nil) saying
    # whether a link from this source is already in Runlight, so its history need not be fetched again: imported
    # from this source before, or the same slug to the same destination brought in some other way.
    module Importer
      def step(_credentials, _cursor, _known)
        raise NotImplementedError, "#{self.class.name} must implement step"
      end
    end
  end
end
