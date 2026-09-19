# frozen_string_literal: true

module ReputableChat
  module Bot
    # When a bot turns up, how long it stays, and what it does while it is
    # there.
    #
    # A bot is either *visiting* -- reading, reacting, occasionally posting --
    # or it is away. A visit ends because something offline took the person's
    # attention, which is a clock and not a quota, so departure is exponential:
    # still being here after ten minutes says nothing about whether they leave
    # in the next one.
    #
    # Only rates are configured. How many posts land in a given visit is
    # whatever happens to fit, which is why a bot's messages arrive in clusters
    # without anything here arranging that.
    class Schedule
      WEEK = 7 * 86_400

      # Spread of the within-visit gap, as the sigma of its log-normal. Not a
      # config key: it is the difference between someone typing steadily and
      # someone typing in fits, which is not a dial worth having. At 0.75 the
      # mean gap lands near 2.3x the mode, which leaves room for the long pause
      # where they are reading rather than typing.
      GAP_SHAPE = 0.75

      class Invalid < StandardError; end

      DEFAULTS = {
        "visits_per_week" => 14.0,
        "visit_minutes" => 12.0,
        "posts_per_week" => 12.0,
        "reactions_per_week" => 45.0,
        "min_gap_seconds" => 10.0,
        "mode_gap_seconds" => 45.0
      }.freeze

      attr_reader :visits_per_week, :posts_per_week, :reactions_per_week

      def initialize(posting = {}, random: Random.new)
        settings = DEFAULTS.merge(posting || {})
        @random  = random

        @visits_per_week    = positive(settings, "visits_per_week")
        @visit_mean         = positive(settings, "visit_minutes") * 60
        @posts_per_week     = non_negative(settings, "posts_per_week")
        @reactions_per_week = non_negative(settings, "reactions_per_week")
        @min_gap            = non_negative(settings, "min_gap_seconds")
        @mode_gap           = positive(settings, "mode_gap_seconds")

        validate!
      end

      # --- the derived shape ------------------------------------------------
      #
      # Everything below follows from the six numbers above. Nothing here is
      # configured twice, so no two settings can contradict each other.

      # Log-normal mu that puts the mode at mode_gap_seconds.
      def gap_mu = Math.log(@mode_gap) + (GAP_SHAPE**2)

      def mean_gap = @min_gap + Math.exp(gap_mu + ((GAP_SHAPE**2) / 2))

      # How many actions a visit actually affords.
      #
      # The obvious answer, visit_length / mean_gap, is wrong by several
      # percent, and wrong in a way that makes posts_per_week quietly
      # optimistic. Actions are a renewal process stopped by an independent
      # exponential deadline, so the count is a geometric series in the gap's
      # Laplace transform: E[N] = phi / (1 - phi) for phi = E[exp(-G/visit)].
      # The log-normal has no closed-form transform, hence the quadrature.
      def actions_per_visit
        @actions_per_visit ||= begin
          phi = gap_laplace(1.0 / @visit_mean)
          phi / (1 - phi)
        end
      end

      def actions_per_week = @visits_per_week * actions_per_visit

      # What a given action turns out to be. The rest of the time the bot is
      # reading, which is most of what anybody does.
      def post_probability     = @posts_per_week / actions_per_week
      def reaction_probability = @reactions_per_week / actions_per_week
      def read_probability     = 1.0 - post_probability - reaction_probability

      # Derived rather than configured: the time away is whatever is left of
      # the week once the visits are taken out.
      def away_mean = (WEEK / @visits_per_week) - @visit_mean

      # --- draws ------------------------------------------------------------

      def away_seconds  = exponential(away_mean)
      def visit_seconds = exponential(@visit_mean)

      # Short and clustered, with the occasional long pause. Never faster than
      # the floor, which is as much a courtesy to the server as it is realism.
      def gap_seconds = @min_gap + Math.exp(gap_mu + (GAP_SHAPE * gaussian))

      def next_action
        roll = @random.rand

        return :post  if roll < post_probability
        return :react if roll < post_probability + reaction_probability

        :read
      end

      # A bot started now should not arrive now -- twenty of them launched
      # together would otherwise burst in unison and then drift apart, which
      # looks nothing like twenty people and hits the server hardest at the
      # least useful moment.
      def initial_delay = away_seconds * @random.rand

      def summary
        format("%.1f visits/week, ~%.0f min each, ~%.1f actions/visit " \
               "(%.0f%% post, %.0f%% react, %.0f%% read), ~%.1f h away between",
               @visits_per_week, @visit_mean / 60, actions_per_visit,
               post_probability * 100, reaction_probability * 100, read_probability * 100,
               away_mean / 3600)
      end

      private

      def exponential(mean) = -mean * Math.log(1 - @random.rand)

      # E[exp(-s * G)] for the within-visit gap, by Simpson's rule over the
      # standard normal behind the log-normal. Six sigma each way is far past
      # where the integrand contributes anything, and it runs once.
      def gap_laplace(rate)
        steps = 240
        low   = -6.0
        step  = 12.0 / steps

        total = (0..steps).sum do |i|
          z      = low + (i * step)
          weight = i.zero? || i == steps ? 1 : (i.odd? ? 4 : 2)
          gap    = @min_gap + Math.exp(gap_mu + (GAP_SHAPE * z))

          weight * normal_pdf(z) * Math.exp(-rate * gap)
        end

        total * step / 3
      end

      def normal_pdf(z) = Math.exp(-(z**2) / 2) / Math.sqrt(2 * Math::PI)

      def gaussian
        u1 = 1 - @random.rand # never 0, so the log is always defined
        u2 = @random.rand

        Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math::PI * u2)
      end

      def validate!
        if away_mean <= 0
          raise Invalid,
                format("visits_per_week %.1f at visit_minutes %.1f leaves no time away; " \
                       "a week only holds %.1f visits of that length",
                       @visits_per_week, @visit_mean / 60, WEEK / @visit_mean)
        end

        return if read_probability >= 0

        raise Invalid,
              format("posts_per_week + reactions_per_week is %.1f but these visits only " \
                     "afford about %.1f actions a week; raise visits_per_week or " \
                     "visit_minutes, or lower mode_gap_seconds",
                     @posts_per_week + @reactions_per_week, actions_per_week)
      end

      def positive(settings, key)
        value = non_negative(settings, key)
        raise Invalid, "#{key} must be greater than zero" unless value.positive?

        value
      end

      def non_negative(settings, key)
        value = Float(settings.fetch(key), exception: false)
        raise Invalid, "#{key} must be a number" if value.nil?
        raise Invalid, "#{key} cannot be negative" if value.negative?

        value
      end
    end
  end
end
