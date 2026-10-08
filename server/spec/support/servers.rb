# frozen_string_literal: true

require "rack/mock"
require "tmpdir"
require "agnostic/server"

# Whole servers in one process, each with its own data directory, talking to
# each other through their Rack apps rather than the network.
module Servers
  Network = Struct.new(:apps) do
    def call(method, address, body)
      uri = URI(address)
      app = apps.fetch("#{uri.scheme}://#{uri.host}")
      env = { method: method.to_s.upcase }
      if body
        env[:input] = JSON.generate(body)
        env["CONTENT_TYPE"] = "application/json"
      end
      response = Rack::MockRequest.new(app).request(method.to_s.upcase, uri.request_uri, env)
      raise "#{address} answered #{response.status}" unless response.status.between?(200, 299)

      JSON.parse(response.body)
    end
  end

  def network = @network ||= Network.new({})

  # A server at http://<name>, peering with the others named.
  def boot(name, peers: [], clock: -> { Time.now.to_i })
    dir = Dir.mktmpdir("agnostic-#{name}")
    (@dirs ||= []) << dir
    settings = Agnostic::Settings.new(
      { "data_dir" => dir, "host" => { "handle" => name },
        "peers" => { "urls" => peers.map { |p| "http://#{p}" } } }, env: { "RACK_ENV" => "development" }
    )
    server = Agnostic::Server.new(settings: settings, clock: clock, http: network)
    network.apps["http://#{name}"] = server.app
    server
  end

  def teardown = Array(@dirs).each { |d| FileUtils.rm_rf(d) }
end
