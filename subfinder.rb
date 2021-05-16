#!/usr/bin/env ruby
# encoding: utf-8
# 

require 'logger'
require 'nokogiri'
require 'mechanize'
require 'shellwords'
require 'ostruct'

$stdout.sync = true

class ZMKFinder
  @@base_url = "http://zmk.pw"

  def initialize(opts)
    @logger = Logger.new($stdout, progname: "zimuku", datetime_format: "%Y-%m-%d %H:%M:%S")
    @agent = Mechanize.new
    @agent.user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 11_2_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/88.0.4324.96 Safari/537.36"
    @force = opts[:force]
  end

  def process(nfo)
    read_nfo(nfo)
    return unless _need_processing?
    return unless find
    download
    extract
    rename
  end

  def read_nfo(nfo)
    doc = File.open(nfo) { |f| Nokogiri::XML(f) }
    if doc.at_css("movie:root")
      @file = OpenStruct.new({
        title: doc.at_css("movie > title").text,
        imdb:  doc.at_css("uniqueid[type=imdb]").text,
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
      episode_str = "S%02dE%02d" % [@file.season, @file.episode]
      @file.title = "#{show[:title]}:#{episode_str}.#{@file.title}" 
      @file.show_title = show[:title]
      @file
    else
      @file = nil
    end
  end

  def find
    @agent.get(_base_url)
    if @file.type == '电影'
      search_path = "/search/?q=" + @file.imdb
      media_path = @agent.get(search_path).at_css(".container .box .item a[href^='/subs/']")["href"]
      @logger.info "---- #{media_path}"
      sub = @agent.get(media_path)
        .css("#subtb > tbody > tr")
        .sort_by {|s| _download_count(s.at_css(">td:nth-last-child(2)").text) }
        .last
    else
      search_path = "/search/?q=" + URI.encode_www_form_component(@file.show_title + " " + @file.year)
      media_item = @agent.get(search_path).
        at_css(".container .box .item:contains('.S%02d') a[href^='/subs']" % [@file.season])
      unless media_item
        @logger.info "未找到字幕"
        return false 
      end
      media_path = media_item['href']
      @logger.info "---- #{media_path}"
      subs = @agent.get(media_path).css("#subtb > tbody > tr")
      sub = subs.select{ |s|
        s.at_css(":has(a[title*='s%02de%02d']), :has(a[title*='S%02dE%02d'])" % [@file.season, @file.episode, @file.season, @file.episode]) 
      }.sort_by {|s| _download_count(s.at_css(">td:nth-last-child(2)").text) }.last
      sub ||= subs.select{ |s|
        s.at_css(":has(a[title*='S%02d.']), :has(a[title*='s%02d.'])" % [@file.season, @file.season]) 
      }.sort_by {|s| _download_count(s.at_css(">td:nth-last-child(2)").text) }.last
    end
    if sub 
      @file.sub_name = sub.at_css("a[href^='/detail/']")["title"]
      @file.path = sub.at_css("a[href^='/detail/']")["href"].sub("detail", "dld")
      @file.downloads = sub.at_css(">td:nth-last-child(2)").text
      @logger.info "找到 '#{@file.sub_name}'"
      @logger.info "---- #{@file.path} 下载量 #{@file.downloads}"
      return true
    else
      @logger.info "未找到字幕"
      return false
    end
  end

  def download
    links = @agent.get(@file.path)
    link = links.links.first.href
    f = @agent.get(link)
    fname = f.header['content-disposition'][/"(.*)"/,1]
    @file.sub_name = fname
    sub_file = File.join(@file.dir, fname)
    f.save!(sub_file)
  end

  def extract
    sub_file = File.join(@file.dir, @file.sub_name)
    if sub_file.end_with?('.rar')
      `unrar e -o+ #{_escape(sub_file)} #{_escape(@file.dir)}`
    elsif sub_file.end_with?('.zip')
      `7z e -y -o#{_escape(@file.dir)} #{_escape(sub_file)}`
    end
  end

  def rename
    if @file.type == '电影'
      Dir["#{_escape(@file.dir)}/*.{sub,idx,ass,srt}"].each do |f|
        _rename_sub(f, @file.filename)
      end
    else
      Dir["#{_escape(@file.dir)}/*.nfo"].each do |nfo|
        e = nfo[/S\d{2}E\d{2}/i]
        next unless e
        prefix = File.basename(nfo).delete_suffix(".nfo")
        Dir.glob("#{_escape(@file.dir)}/*#{e}*.{sub,idx,ass,srt}", File::FNM_CASEFOLD).each do |f|
          _rename_sub(f, prefix)
        end
      end
    end
  end

  private

  def _rename_sub(f, prefix)
    unless File.basename(f).start_with?(prefix)
      old_name = File.basename(f)
      new_name = prefix + "." + old_name
      @logger.info "重命名 #{old_name}"
      @logger.info "  -> #{new_name}"
      File.rename(f, File.join(File.dirname(f), new_name))
    end
  end

  def _escape(str)
    Shellwords.escape(str)
  end

  def _download_count(c)
    c.include?("万") ? (c.to_f * 10000).to_i : c.to_i
  end

  def _need_processing?
    return false unless @file and @file.imdb
    @logger.info "#{@file.type} [#{@file.title}], imdb: #{@file.imdb}"
    return true  if @force
    existing = Dir["#{_escape(@file.dir)}/#{_escape(@file.filename)}.*.{srt,sub,ass}"]
    if existing.empty?
      return true  
    else
      existing.each do |f|
        @logger.info "已有 #{File.basename(f)}"
      end
      return false
    end
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


  def _base_url
    @@base_url
  end

end

def run_finder(finder, dir)
  log = Logger.new(STDOUT, datetime_format: "%Y-%m-%d %H:%M:%S")
  log.info "....................启动 SUBFINDER"
  t = Time.now()

  Dir["#{dir}/**/*.nfo"].sort.each do |nfo|
    finder.process(nfo)
  end
  delta = (Time.now() - t).round(2)
  log.info "....................一共运行 #{delta} 秒"
end

if __FILE__ == $0
  require 'optparse'
  opts = {}
  OptionParser.new do |o|
    o.banner = <<~USAGE
    Usage: #{$0} [OPTIONS] [PATH]

           PATH defaults to $PWD

    USAGE

    o.on("-f", "--force", "Force download subs even if there exists some") do |v|
      opts[:force] = v
    end
    o.on("-d", "--daemon", "Run as daemon") do |v|
      opts[:daemon] = v
    end
  end.parse!

  dir = ARGV.first || "."

  finder = ZMKFinder.new(opts)

  if opts[:daemon]
    run = true
    trap 'TERM', lambda { run = false }

    while run
      run_finder(finder, dir)
      sleep 7200
    end
  else
    run_finder(finder, dir)
  end
end
