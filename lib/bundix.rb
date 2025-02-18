require 'bundler'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'pp'

require_relative 'bundix/version'
require_relative 'bundix/source'
require_relative 'bundix/nixer'

class Bundix
  NIX_INSTANTIATE = 'nix-instantiate'
  NIX_PREFETCH_URL = 'nix-prefetch-url'
  NIX_PREFETCH_GIT = 'nix-prefetch-git'
  NIX_HASH = 'nix-hash'
  NIX_SHELL = 'nix-shell'

  SHA256_32 = %r(^[a-z0-9]{52}$)

  attr_reader :options

  attr_accessor :fetcher

  class Dependency < Bundler::Dependency
    def initialize(name, version, options={}, &blk)
      super(name, version, options, &blk)
      @bundix_version = version
    end

    attr_reader :version
  end

  def initialize(options)
    @options = { quiet: false, tempfile: nil }.merge(options)
    @fetcher = Fetcher.new
  end

  def convert
    cache = parse_gemset
    lock = parse_lockfile
    dep_cache = build_depcache(lock)
    if options[:all_target_platforms]
      target_platforms = lock.platforms
    else
      target_platforms = [Gem::Platform.new(options[:target_platform])]
    end
    gemset = spec_set_for(lock, target_platforms).each.with_object(empty_gemset) do |spec, gems|
      if spec.platform == "ruby"
        matching_platforms = ["ruby"]
      else
        matching_platforms = target_platforms.select { |p| spec.platform === p }
      end
      gem = find_cached_spec(spec, cache, matching_platforms) || convert_spec(spec, dep_cache)

      if spec.dependencies.any?
        gem['dependencies'] = spec.dependencies.map(&:name) - ['bundler']
      end

      if options[:all_target_platforms]
        matching_platforms.each do |platform|
          gems[platform.to_s][spec.name] = gem
        end
      else
        gems[spec.name] = gem
      end
    end
    if options[:all_target_platforms] && gemset.key?("ruby")
      (gemset.keys - ["ruby"]).each do |platform_name|
        gemset[platform_name] = gemset["ruby"].merge(gemset[platform_name])
      end
      gemset.delete("ruby") unless target_platforms.include?("ruby")
    end
    gemset
  end

  def groups(spec, dep_cache)
    {groups: dep_cache.fetch(spec.name).groups}
  end

  PLATFORM_MAPPING = {}

  {
    "ruby" => [{engine: "ruby"}, {engine:"rbx"}, {engine:"maglev"}],
    "mri" => [{engine: "ruby"}, {engine: "maglev"}],
    "rbx" => [{engine: "rbx"}],
    "jruby" => [{engine: "jruby"}],
    "mswin" => [{engine: "mswin"}],
    "mswin64" => [{engine: "mswin64"}],
    "mingw" => [{engine: "mingw"}],
    "truffleruby" => [{engine: "ruby"}],
    "x64_mingw" => [{engine: "mingw"}],
  }.each do |name, list|
    PLATFORM_MAPPING[name] = list
    %w(1.8 1.9 2.0 2.1 2.2 2.3 2.4 2.5 2.6).each do |version|
      PLATFORM_MAPPING["#{name}_#{version.sub(/[.]/,'')}"] = list.map do |platform|
        platform.merge(:version => version)
      end
    end
  end

  def platforms(spec, dep_cache)
    # c.f. Bundler::CurrentRuby
    platforms = dep_cache.fetch(spec.name).platforms.map do |platform_name|
      PLATFORM_MAPPING[platform_name.to_s]
    end.flatten

    {platforms: platforms}
  end

  def convert_spec(spec, dep_cache)
    {
      version: spec.version.to_s,
      source: Source.new(spec, fetcher).convert,
      platform: spec.platform.to_s,
    }.merge(platforms(spec, dep_cache)).merge(groups(spec, dep_cache))
  rescue => ex
    warn "Skipping #{spec.name}: #{ex}"
    puts ex.backtrace
    {}
  end

  def find_cached_spec(spec, cache, matching_platforms)
    cached = nil
    if options[:all_target_platforms]
      matching_platforms.each do |platform|
        cached = cache[platform.to_s][spec.name]
        break if cached
      end
    else
      cached = cache[spec.name]
    end
    return unless cached
    return unless spec.platform === Gem::Platform.new(cached['platform'])
    return unless cached_source = cached['source']

    case spec_source = spec.source
    when Bundler::Source::Git
      return unless cached_source['type'] == 'git'
      return unless cached_rev = cached_source['rev']
      return unless spec_rev = spec_source.options['revision']
      return unless spec_rev == cached_rev
      cached
    when Bundler::Source::Rubygems
      return unless cached_source['type'] == 'gem'
      return unless cached['version'] == spec.version.to_s
      return unless (spec_source.options['remotes'].map { |r| r.sub(/\/+$/, '') } & cached_source['remotes']).any?
      cached
    end
  end

  def build_depcache(lock)
    definition = Bundler::Definition.build(options[:gemfile], options[:lockfile], false)
    dep_cache = {}

    definition.dependencies.each do |dep|
      dep_cache[dep.name] = dep
    end

    lock.specs.each do |spec|
      dep_cache[spec.name] ||= Dependency.new(spec.name, nil, {})
    end

    begin
      changed = false
      lock.specs.each do |spec|
        as_dep = dep_cache.fetch(spec.name)

        spec.dependencies.each do |dep|
          cached = dep_cache.fetch(dep.name) do |name|
            if name != "bundler"
              raise KeyError, "Gem dependency '#{name}' not specified in #{lockfile}"
            end
            dep_cache[name] = Dependency.new(name, lock.bundler_version, {})
          end

          if !((as_dep.groups - cached.groups) - [:default]).empty? or !(as_dep.platforms - cached.platforms).empty?
            changed = true
            dep_cache[cached.name] = (Dependency.new(cached.name, nil, {
              "group" => as_dep.groups | cached.groups,
              "platforms" => as_dep.platforms | cached.platforms
            }))

            cc = dep_cache[cached.name]
          end
        end
      end
    end while changed

    return dep_cache
  end

  def empty_gemset
    if options[:all_target_platforms]
      Hash.new { |h, k| h[k] = {} }
    else
      {}
    end
  end

  def parse_gemset
    path = File.expand_path(options[:gemset])
    return empty_gemset unless File.file?(path)
    json = Bundix.sh(NIX_INSTANTIATE, '--eval', '-E', %(
      builtins.toJSON (import #{Nixer.serialize(path)}))
    )
    cache = empty_gemset.merge(JSON.parse(json.strip.gsub(/\\"/, '"')[1..-2]))
    if options[:all_target_platforms] && !cache.key?("ruby")
      cache.values.each do |platform_cache|
        platform_cache.each do |name, spec|
          next if cache["ruby"][name]

          cache["ruby"][name] = spec if spec["platform"] == "ruby"
        end
      end
    end
    cache
  end

  def parse_lockfile
    Bundler::LockfileParser.new(File.read(options[:lockfile]))
  end

  def spec_set_for(lock, target_platforms)
    spec_set = Bundler::SpecSet.new(lock.specs)
    case spec_set.method(:for).parameters.index { |param| param[1].to_s.include?('platforms') }
    when 1
      spec_set.for(lock.dependencies.values, target_platforms)
    when 2
      spec_set.for(lock.dependencies.values, false, target_platforms)
    else
      raise ArgumentError, "looks like this version of Bundler is not supported"
    end
  end

  def self.sh(*args, &block)
    out, status = Open3.capture2(*args)
    unless block_given? ? block.call(status, out) : status.success?
      puts "$ #{args.join(' ')}" if $VERBOSE
      puts out if $VERBOSE
      fail "command execution failed: #{status}"
    end
    out
  end
end
