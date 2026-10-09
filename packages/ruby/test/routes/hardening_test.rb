# frozen_string_literal: true

require "test_helper"
require_relative "make"

# The route-level part of hardening.test.ts: a link domain's check. The rest belongs to the core, safefetch, and the stores.
class RoutesHardeningTest < RoutesTestCase
  def test_a_link_domains_check_says_where_the_domain_should_point_for_its_setup_steps
    answers404 = Object.new
    def answers404.fetch(_url, _init = {})
      Runlight::Http::Response.new("no", status: 404)
    end
    rl = RoutesMake.runlight({ "site" => { "hostnames" => ["example.com"] }, "fetcher" => answers404 })
    rl.init
    rl.store.add_link_domain("go.example.net", "default", 0)
    check = RoutesMake.body(rl.routes({ "token" => "secret" }).handle(RoutesMake.owner("/runlight/api/link-domains/go.example.net/check")))
    assert_equal "example.com", check["target"]["host"], "this dashboard's own name, for a CNAME"
    assert_kind_of Array, check["target"]["addresses"]
    assert_equal false, check["working"]
  end
end
