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
  #   agnostic server does with servers it cannot reach. One that answered but
  #   did not have the file (a 404) is put off too, for missing_penalty of the
  #   time a failure would cost -- it answered, so it loses less -- and a miss
  #   does not make the next failure's wait any longer.
  #
  # Every outcome -- :reached, :missing or :unreached -- is reported to the
  # agnostic server (reporter),
  # where it counts toward the account's rating with that server's own
  # contacts -- so what the chat learns outlasts a restart, and the next
  # choice takes it into account.
  #
  # An address is looked up once, checked, and that address is the one
  # connected to, so a name cannot answer with a public address for the check
  # and a private one for the connection.
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
                   http: nil, clock: -> { Time.now.to_i }, random: Random.new, resolver: Resolv,
                   reporter: nil, missing_penalty: BigDecimal("0.25"))
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
      @reporter = reporter
      @missing_penalty = BigDecimal(missing_penalty.to_s).clamp(0, 1)
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
        next missed(account) if bytes == :missing

        # Checked before anything is stored, so a server answering with some
        # other image leaves nothing behind.
        if bytes.is_a?(String) && Digest::SHA256.hexdigest(bytes) == name[0, 64] && @images.store(bytes) == name
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
    def allowed?(url) = !address(url).nil?

    # The address to connect to for a url, looked up once and checked; nil
    # when it may not be contacted. Every address a name has must pass, so a
    # name cannot hide a private one behind a public one.
    def address(url)
      uri = URI.parse(url)
      return nil unless %w[http https].include?(uri.scheme) && uri.host
      return nil if @require_https && uri.scheme != "https"

      addresses = @resolver.getaddresses(uri.host)
      return nil if addresses.empty?
      return nil if !@allow_private && addresses.any? { |a| private?(a) }

      addresses.first
    rescue URI::InvalidURIError, IPAddr::InvalidAddressError
      nil
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

    # Remembered once it passes. One that fails -- not there, or answering
    # as another account -- is a failure like any other, put off and reported,
    # and checked again when it comes back round.
    def verified?(account, url)
      key = [account, url]
      return true if @verified[key]

      body = get("#{url}/api/host")
      passed = begin
        body.is_a?(String) && JSON.parse(body).dig("host", "account") == account
      rescue JSON::ParserError
        false
      end
      passed ? @verified[key] = true : failed(account)
      passed
    end

    def succeeded(account)
      @lock.synchronize do
        @failures.delete(account)
        @next_try.delete(account)
      end
      report(account, :reached)
    end

    def failed(account)
      @lock.synchronize do
        @failures[account] += 1
        @next_try[account] = @clock.call + backoff(@failures[account])
      end
      report(account, :unreached)
    end

    # It answered without the file: put off for missing_penalty of what one
    # more failure would cost, without counting as a failure.
    def missed(account)
      @lock.synchronize do
        delay = (@missing_penalty * backoff(@failures[account] + 1)).round
        @next_try[account] = [@next_try[account], @clock.call + delay].max
      end
      report(account, :missing)
    end

    def backoff(failures) = [BACKOFF_FIRST * (2**(failures - 1)), BACKOFF_MOST].min

    # Best effort: a report that does not arrive costs a rating one data point.
    def report(account, outcome)
      @reporter&.call(account, outcome)
    rescue StandardError
      nil
    end

    # The body; :missing for a 404, which is an answer; or nil for anything
    # else, or a body over the image limit. The address checked is the one
    # connected to.
    def get(url)
      ip = address(url)
      ip && @http.call(url, @images.max_bytes, ip)
    end

    def over_the_network(url, max_bytes, ip)
      uri = URI(url)
      connection = Net::HTTP.new(uri.host, uri.port)
      connection.ipaddr = ip
      connection.use_ssl = uri.scheme == "https"
      connection.open_timeout = TIMEOUT
      connection.read_timeout = TIMEOUT
      connection.start do |http|
        request = Net::HTTP::Get.new(uri)
        request[PEER_HEADER] = "1"
        http.request(request) do |response|
          return :missing if response.is_a?(Net::HTTPNotFound)
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
