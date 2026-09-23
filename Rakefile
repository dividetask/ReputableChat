# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:spec) do |t|
  t.libs << "lib" << "spec"
  t.test_files = FileList["spec/**/*_spec.rb"]
  t.warning = false
end

desc "Readable dump of the database (rake dump, or dump[messages] / dump[users,attestations])"
task :dump, [:sections] do |_task, args|
  $LOAD_PATH.unshift "lib"
  require "reputable_chat/dump"
  require "reputable_chat/server_config"

  settings = ReputableChat::ServerConfig.load
  url = settings.fetch("database_url")
  puts "database: #{url}"
  puts

  store = ReputableChat::Store::Database.new(url)
  # Rake splits on the commas inside the brackets itself, so dump[users,vaults]
  # arrives as one named argument and one extra rather than as a single string.
  # Reading only the named one silently dumped the first section and dropped the
  # rest, which looks exactly like a section being empty.
  named = [args[:sections], *args.extras].compact
  sections = named.flat_map { |value| value.split(/[\s,]+/) }.reject(&:empty?)

  ReputableChat::Dump.new(store).render(*(sections.empty? ? [] : [sections]))
end

desc "Print the reputation curve and ladder for the current config"
task :curve do
  $LOAD_PATH.unshift "lib"
  require "reputable_chat/config"
  require "reputable_chat/reputation/engine"
  require "reputable_chat/store/memory"

  config = ReputableChat::Config.load
  engine = ReputableChat::Reputation::Engine.new(config: config, store: ReputableChat::Store::Memory.new)

  puts "k = #{engine.ladder.k.to_s('F')}   max_hops = #{engine.ladder.max_hops}"
  puts "stranger ceiling = #{engine.ladder.stranger_ceiling.to_s('F')}   max_accounts = #{engine.ladder.max_accounts}"
  puts "cap reached at #{engine.curve.saturation_point} net votes"
  puts
  puts "hops   weight"
  (0..engine.ladder.max_hops).each { |d| puts format("%5d  %s", d, engine.ladder.weight(d).to_s("F")) }
  puts
  puts "votes  value"
  [1, 2, 3, 5, 10, 20, 30, 36].each { |n| puts format("%5d  %s", n, engine.curve.value(n).to_s("F")) }
  puts
  k3 = engine.ladder.k**3
  puts "report-rule window: curve(1)=#{engine.curve.value(1).to_s('F')} < " \
       "k**3=#{k3.to_s('F')} < curve(2)=#{engine.curve.value(2).to_s('F')}"
end

desc "Generate the genesis user record (Tim) for committing"
task :genesis do
  # Options (--handle, --bio, --words, --path) mean running the script
  # directly: rake reads anything after the task name as another task.
  ruby "-Ilib", "script/generate_genesis.rb"
end

task default: :spec
