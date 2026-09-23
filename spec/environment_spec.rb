# frozen_string_literal: true

require_relative "spec_helper"
require_relative "genesis_fixture"
require "reputable_chat/environment"
require "reputable_chat/genesis"
require "reputable_chat/operator"
require "open3"
require "json"
require "tmpdir"

# There are two genesis accounts, and the whole point of the split is that one
# of them is public. Everything here protects the line between them.
class EnvironmentSpec < Minitest::Test
  Environment = ReputableChat::Environment
  Genesis     = ReputableChat::Genesis
  Operator    = ReputableChat::Operator

  def setup
    @rack_env = ENV.fetch("RACK_ENV", nil)
    Genesis.reset!
  end

  def teardown
    ENV["RACK_ENV"] = @rack_env
    Genesis.reset!
  end

  def as(environment)
    ENV["RACK_ENV"] = environment
    Genesis.reset!
    yield
  end

  # RULE: anything that is not explicitly production is development. The
  # failure that matters is a production box quietly running development's
  # published key, so the unset default has to be the harmless one.
  def test_an_unset_environment_is_development
    ENV.delete("RACK_ENV")

    assert Environment.development?
    refute Environment.production?
  end

  def test_the_two_environments_use_different_files
    dev = as(Environment::DEVELOPMENT) { [Genesis.path, Operator.seed_path] }
    prod = as(Environment::PRODUCTION) { [Genesis.path, Operator.seed_path] }

    refute_equal dev, prod
    assert_includes dev.first, "development"
    assert_includes prod.first, "production"
  end

  # RULE: production refuses the development genesis. Its seed is committed and
  # therefore public -- everyone who has cloned the repository could sign
  # releases and announcements as it.
  #
  # Compared by key rather than by filename, because the realistic mistake is
  # copying the development record into place, not misnaming it.
  def test_production_refuses_the_development_genesis_under_any_filename
    Dir.mktmpdir do |dir|
      development = Genesis.load(path: Genesis.path(Environment::DEVELOPMENT))
      copied = File.join(dir, "production.json")
      File.write(copied, JSON.generate(development.to_h))

      as(Environment::PRODUCTION) do
        error = assert_raises(Genesis::WrongEnvironment) do
          Genesis.refuse_development_in_production(Genesis.load(path: copied))
        end
        assert_match(/public/, error.message)
      end
    end
  end

  def test_production_accepts_a_genesis_that_is_not_developments
    as(Environment::PRODUCTION) do
      own = GenesisFixture.build

      assert_equal own, Genesis.refuse_development_in_production(own)
    end
  end

  def test_development_is_not_refused_in_development
    as(Environment::DEVELOPMENT) do
      genesis = Genesis.load(path: Genesis.path(Environment::DEVELOPMENT))

      assert_equal genesis, Genesis.refuse_development_in_production(genesis)
    end
  end

  # --- what git will and will not carry -----------------------------------

  # RULE: the development seed is committed on purpose, so a fresh clone can
  # sign as the genesis account without being handed a secret.
  def test_the_development_seed_is_committed
    refute ignored?("config/genesis/development.seed"),
           "development's seed must not be ignored -- a clone needs it"
    assert File.exist?(Operator.path_for(Environment::DEVELOPMENT))
  end

  # RULE: every other seed is ignored. The rule is written as "ignore all, then
  # un-ignore development", so a new environment is refused by default rather
  # than committed by omission.
  def test_every_other_seed_is_ignored
    %w[production staging whatever].each do |environment|
      assert ignored?("config/genesis/#{environment}.seed"),
             "#{environment}'s seed must be ignored"
    end
  end

  def test_no_seed_but_developments_is_tracked
    tracked, = Open3.capture2("git", "ls-files", "config/genesis/")
    seeds = tracked.split("\n").grep(/\.seed\z/)

    assert_equal ["config/genesis/development.seed"], seeds
  end

  def ignored?(path)
    _, status = Open3.capture2e("git", "check-ignore", "-q", path)
    status.success?
  end
end
