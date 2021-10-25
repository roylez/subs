#!/usr/bin/env ruby
# encoding: utf-8
# 

require 'logger'
require 'nokogiri'
require 'mechanize'
require 'rchardet'
require 'shellwords'
require 'ostruct'
require 'json'

require_relative 'zimuku'
# subhd is broken and because of its unfriendly behaviour to automated requests, it is disabled
# require_relative 'subhd'

$stdout.sync = true

SUB_FORMATS=%w(ass ssa srt sub)

class Subs

  def initialize(opts)
    @logger = Logger.new($stdout, datetime_format: "%Y-%m-%d %H:%M:%S")
    @force = opts[:force]
    @providers = [ Zimuku.new(opts) ]
  end

  def process(nfo)
    read_nfo(nfo)
    return unless _need_processing?
    sub_files = @providers.reduce(nil) do |file, sub|
      next unless sub.find(@file)
      break sub.download
    end
    if sub_files
      @file.sub_files = sub_files
      extract
      rename
    end
  end

  def read_nfo(nfo)
    doc = File.open(nfo) { |f| Nokogiri::XML(f) }
    if doc.at_css("movie:root")
      @file = OpenStruct.new({
        title: doc.at_css("movie > title").text,
        imdb:  doc.at_css("uniqueid[type=imdb]")&.text,
        filename: File.basename(nfo).delete_suffix(".nfo"),
        dir: File.dirname(nfo),
        type: "电影"
      })
    elsif doc.at_css("episodedetails:root")
      @file = OpenStruct.new({
        title: doc.at_css("episodedetails > title").text,
        filename: File.basename(nfo).delete_suffix(".nfo"),
        dir: File.dirname(nfo),
        season: doc.at_css("episodedetails > season").text.to_i,
        episode: doc.at_css("episodedetails > episode").text.to_i,
        type: "剧集"
      })
      show = _get_show_info(File.expand_path("../", @file.dir))
      season = _get_season_info(File.expand_path(@file.dir))
      @file.imdb = show[:imdb]
      @file.year = season[:year]
      @file.episode_str = "S%02dE%02d" % [@file.season, @file.episode]
      @file.season_str = "S%02d" % [@file.season]
      @file.title = "#{show[:title]}:#{@file.episode_str}" 
      @file.show_title = show[:title]
      @file
    else
      @file = nil
    end
  end

  def extract
    @file.sub_files.each do |f|
      sub_file = File.join(@file.dir, f)
      case File.extname(sub_file)
      when ".rar"  ; %x[ unrar e -o+ #{_escape(sub_file)} #{_escape(@file.dir)} ]
      when ".7z"   ; %x[ 7z e -y -o#{_escape(@file.dir)} #{_escape(sub_file)} ]
      when ".zip"  ; %x[ 7z e -y -o#{_escape(@file.dir)} #{_escape(sub_file)} ]
      when ".lzma" ; %x[ 7z e -y -o#{_escape(@file.dir)} #{_escape(sub_file)} ]
      else
        @logger.info "未解压缩 #{sub_file}"
      end
    end
  end

  def rename
    if @file.type == '电影'
      _glob_subs("#{_escape(@file.dir)}/").each do |f|
        _rename_sub(f, @file.filename)
      end
    else
      Dir.glob("#{_escape(@file.dir)}/*#{@file.episode_str}*.nfo", File::FNM_CASEFOLD).each do |nfo|
        prefix = File.basename(nfo).delete_suffix(".nfo")
        _glob_subs("#{_escape(@file.dir)}/*#{@file.episode_str}").each do |f|
          _rename_sub(f, prefix)
        end
      end
    end
  end

  private

  def _rename_sub(f, prefix)
    name = File.basename(f)
    ext = File.extname(name)
    lang = File.basename(name, '.*').split(/[.-]/).last
    lang = lang =~ /(体|文|en|chs|cht|zh|cn|tw)/i ? ".#{lang}" : _fallback_lang(f)
    new_name = prefix + lang + ext
    unless name == new_name
      @logger.info "重命名 #{name}"
      @logger.info "  -> #{new_name}"
      File.rename(f, File.join(File.dirname(f), new_name))
    else
      @logger.info "无需重命名 #{name}"
    end
  end

  def _escape(str)
    Shellwords.escape(str)
  end

  def _fallback_lang(f)
    content = open(f).read()
    encoding = CharDet.detect(content)["encoding"]
    c = encoding == 'utf-8' ? content : content.force_encoding(encoding).encode('utf-8')
    !!( c =~ /\p{Han}/ ) ? '.中文' : ''
  end

  def _need_processing?
    return false unless @file
    unless @file.imdb
      @logger.warn "#{@file.type} [#{@file.title}], imdb: 未知，略过"
      return false
    end
    existing = _glob_subs("#{_escape(@file.dir)}/#{_escape(@file.filename)}", false)
    unless existing.empty?
      @logger.info "#{@file.type} [#{@file.title}], imdb: #{@file.imdb}, 已有 #{existing.size} 个字幕"
    else
      @logger.info "#{@file.type} [#{@file.title}], imdb: #{@file.imdb}"
    end
    @force || existing.empty?
  end

  def _get_show_info(dir)
    Dir["#{_escape(dir)}/*.nfo"].each do |nfo|
      doc = File.open(nfo) { |f| Nokogiri::XML(f) }
      if doc.at_css("tvshow:root")
        return { title: doc.at_css("tvshow:root > title").text, imdb: doc.at_css("uniqueid[type=imdb]").text }
      end
    end
    return {}
  end
  def _get_season_info(dir)
    Dir["#{_escape(dir)}/*.nfo"].each do |nfo|
      doc = File.open(nfo) { |f| Nokogiri::XML(f) }
      if doc.at_css("season:root")
        return { year: doc.at_css("season:root > year").text }
      end
    end
    return {}
  end

  def _glob_subs(path, include_idx = true)
    formats = include_idx ? ( SUB_FORMATS + ["idx"] ) : SUB_FORMATS
    Dir.glob("#{path}*.{#{formats.join(',')}}", File::FNM_CASEFOLD)
  end
end

def run_finder(finder, dir)
  log = Logger.new(STDOUT, datetime_format: "%Y-%m-%d %H:%M:%S")
  log.info "....................启动 SUBS"
  t = Time.now()

  Dir["#{dir}/**/*.nfo"].sort.each do |nfo|
    finder.process(nfo)
  end
  delta = (Time.now() - t).round(2)
  log.info "....................一共运行 #{delta} 秒"
end

def get_env(var, type=:boolean)
  res = ENV[var] && ENV[var]
  case type
  when :boolean; res && res != '0'
  when :integer; res.to_i
  else; res
  end
end

if __FILE__ == $0
  require 'optparse'
  opts = {
    force: get_env('SUBS_FORCE'),
  }
  sleep_interval = get_env('SUBS_INTERVAL', :integer)
  sleep_interval = sleep_interval > 0 ? sleep_interval : 7200
  OptionParser.new do |o|
    o.banner = <<~USAGE
    Usage: #{$0} [OPTIONS] [PATH]

           PATH defaults to $PWD

    USAGE

    o.on("-f", "--force", "Force download subs even if there exists some (default false)") do |v|
      opts[:force] = v
    end
    o.on("-d", "--daemon", "Run as daemon") do |v|
      opts[:daemon] = v
    end
  end.parse!

  dir = ARGV.first || "."

  finder = Subs.new(opts)

  if opts[:daemon]
    run = true
    begin
      trap('TERM') { puts "中止执行"; exit }

      while run
        run_finder(finder, dir)
        sleep( sleep_interval )
      end
    rescue Interrupt => e
      puts "用户取消"
    end
  else
    run_finder(finder, dir)
  end
end
