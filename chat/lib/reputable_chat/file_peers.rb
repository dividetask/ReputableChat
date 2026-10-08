# frozen_string_literal: true

require "bigdecimal"
require "digest"
require "ipaddr"
require "json"
require "net/http"
require "resolv"
require "uri"

module ReputableChat
  # Fetching a file this server does not have from the other chat servers.
  #
  # Records name files by the SHA-256 of their bytes, but the chain does not
  # carry the bytes: each chat server stores what its own people upload. When
  # somebody asks this one for a file it lacks, it asks the chat servers that
  # announced themselves (Chain::Service) and keeps the bytes only if they hash
  # to the name the record signed, so no server can substitute another file.
  #
  # Which server to ask:
  # - only one that answers at its announced address as the account that
  #   announced it, checked once per address;
  # - never one at a private, loopback or link-local address unless
  #   allow_private_peers is set, and only over https in production -- anyone
  #   can announce an address, and this keeps one from pointing every chat
  #   server at somebody's internal network;
  # - chosen at random, weighted by what the agnostic server rates its account
  #   (the same account: a chat server shares its agnostic server's), and never
  #   one rated below zero;
  # - not one that failed lately: each failure puts it off for longer, as the
  #   agnostic server does with servers it cannot reach.
  #
  # A request from another chat server (PEER_HEADER) is answered from what is
  # here and never passed on, so two servers cannot ask each other in circles.
  class FilePeers
    PEER_HEADER = "X-ReputableChat-Peer"
    ATTEMPTS = 5
    TIMEOUT = 5
    MISS_SECONDS = 600
    BACKOFF_FIRST = 60
    BACKOFF_MOST = 86_400

    def initialize(mirror:, chain:, images:, host:, allow_private:, require_https:,
                   http: nil, clock: -> { Time.now.to_i }, random: Random.new, resolver: Resolv)
      @mirror = mirror
      @chain = chain
      @images = images
      @host = host
      @allow_private = allow_private
      @require_https = require_https
      @http = http || method(:over_the_network)
      @clock = clock
      @random = random
      @resolver = resolver
      @verified = {}
      @failures = Hash.new(0)
      @next_try = Hash.new(0)
      @missed = {}
      @lock = Mutex.new
    end

    # The name it was stored under, or nil when no server had it.
    def fetch(name)
      return nil if (@missed[name] || 0) > @clock.call

      candidates(name).first(ATTEMPTS).each do |account, url|
        bytes = get("#{url}/images/#{name}")
        # Checked before anything is stored, so a server answering with some
        # other image leaves nothing behind.
        if bytes && Digest::SHA256.hexdigest(bytes) == name[0, 64] && @images.store(bytes) == name
          succeeded(account)
          return name
        end
        failed(account)
      end
      @missed[name] = @clock.call + MISS_SECONDS
      nil
    end

    # Announced servers worth asking, in the order to ask them.
    def candidates(_name = nil)
      ratings = begin
        @chain.ratings
      rescue StandardError
        {}
      end
      now = @clock.call

      pool = @mirror.services.filter_map do |account, url|
        next if account == @host.account || url.nil?
        next if @next_try[account] > now
        next unless allowed?(url)

        rating = ratings.dig(account, "reputation")
        next if rating && BigDecimal(rating).negative?

        [account, url, weight(rating)]
      end
      pool = pool.select { |account, url, _| verified?(account, url) }
      order(pool).map { |account, url, _| [account, url] }
    end

    # Whether a url may be contacted at all: http(s), https in production, and
    # no private address unless allowed.
    def allowed?(url)
      uri = URI.parse(url)
      return false unless %w[http https].include?(uri.scheme) && uri.host
      return false if @require_https && uri.scheme != "https"
      return true if @allow_private

      addresses = @resolver.getaddresses(uri.host)
      !addresses.empty? && addresses.none? { |a| private?(a) }
    rescue URI::InvalidURIError, IPAddr::InvalidAddressError
      false
    end

    private

    def private?(address)
      ip = IPAddr.new(address)
      ip.private? || ip.loopback? || ip.link_local? || ip.to_s == "0.0.0.0" || ip.to_s == "::"
    end

    # Unrated servers count once; a positive rating counts for more.
    def weight(rating)
      return 1.0 unless rating

      1.0 + (BigDecimal(rating) * 100).to_f.clamp(0, 100)
    end

    # A weighted shuffle: each draw picks in proportion to weight.
    def order(pool)
      remaining = pool.dup
      ordered = []
      until remaining.empty?
        point = @random.rand * remaining.sum { |p| p[2] }
        index = remaining.index { |p| (point -= p[2]) < 0 } || (remaining.size - 1)
        ordered << remaining.delete_at(index)
      end
      ordered
    end

    def verified?(account, url)
      key = [account, url]
      return @verified[key] if @verified.key?(key)

      body = get("#{url}/api/host")
      @verified[key] = body && JSON.parse(body).dig("host", "account") == account
    rescue JSON::ParserError
      @verified[key] = false
    end

    def succeeded(account)
      @lock.synchronize do
        @failures.delete(account)
        @next_try.delete(account)
      end
    end

    def failed(account)
      @lock.synchronize do
        @failures[account] += 1
        delay = [BACKOFF_FIRST * (2**(@failures[account] - 1)), BACKOFF_MOST].min
        @next_try[account] = @clock.call + delay
      end
    end

    # The body, or nil for anything but a 200 within the image limit.
    def get(url) = @http.call(url, @images.max_bytes)

    def over_the_network(url, max_bytes)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT,
                                          read_timeout: TIMEOUT) do |http|
        request = Net::HTTP::Get.new(uri)
        request[PEER_HEADER] = "1"
        http.request(request) do |response|
          return nil unless response.is_a?(Net::HTTPOK)

          body = +""
          response.read_body do |chunk|
            body << chunk
            return nil if body.bytesize > max_bytes
          end
          return body
        end
      end
    rescue StandardError
      nil
    end
  end
end
