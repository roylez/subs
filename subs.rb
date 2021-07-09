#!/usr/bin/env ruby
# encoding: utf-8
# 

require 'logger'
require 'nokogiri'
require 'mechanize'
require 'shellwords'
require 'ostruct'
require 'json'

$stdout.sync = true

class Zimuku
  def initialize(opts)
    @logger = Logger.new($stdout, progname: "字幕库", datetime_format: "%Y-%m-%d %H:%M:%S")
    @agent = Mechanize.new
    @agent.user_agent_alias = "Mac Safari"
    @season_item_cache = {}
    @force = opts[:force]
  end

  def find(file)
    @file = file
    @agent.get(_base_url)
    unless media_item = _search_item()
      @logger.info "未找到字幕"
      return false 
    end
    media_path = media_item['href']
    @logger.info "---- #{_url(media_path)}"
    if @file.type == '电影'
      sub = @agent.get(media_path)
        .css("#subtb > tbody > tr")
        .sort_by {|s| _download_count(s.at_css(">td:nth-last-child(2)").text) }
        .last
    else
      subs = @agent.get(media_path).css("#subtb > tbody > tr")
      sub = subs.select{ |s|
        s.at_css(":has(a[title*='#{@file.episode_str}']), :has(a[title*='#{@file.episode_str.downcase}'])")
      }.sort_by {|s| _download_count(s.at_css(">td:nth-last-child(2)").text) }.last
      sub ||= subs.select{ |s|
        s.at_css(":has(a[title*='#{@file.season_str}.']), :has(a[title*='#{@file.season_str.downcase}.'])")
      }.sort_by {|s| _download_count(s.at_css(">td:nth-last-child(2)").text) }.last
    end
    if sub 
      @file.sub_name = sub.at_css("a[href^='/detail/']")["title"]
      @file.path = sub.at_css("a[href^='/detail/']")["href"].sub("detail", "dld")
      @file.downloads = sub.at_css(">td:nth-last-child(2)").text
      @logger.info "找到 '#{@file.sub_name}', 下载量 #{@file.downloads}"
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
    fname = f
      .header['content-disposition'][/"(.*)"/,1]
      .encode('utf-8', invalid: :replace, undef: :replace)
    sub_file = File.join(@file.dir, fname)
    f.save!(sub_file)
    [ fname ]
  end

  private

  def _download_count(c)
    c.include?("万") ? (c.to_f * 10000).to_i : c.to_i
  end

  def _base_url
    ENV['ZIMUKU_URL'] || "http://zmk.pw"
  end

  def _url(path)
    URI.join(_base_url, path).to_s
  end

  def _search_item()
    if @file.type == '电影'
      path = "/search/?q=" + @file.imdb
      item = @agent
        .get(path)
        .at_css(".container .box .item a[href^='/subs/']")
    else
      path = "/search/?q=" + URI.encode_www_form_component(@file.show_title + " " + @file.year)
      return @season_item_cache[path] if @season_item_cache.key?(path)
      item = @agent
        .get(path)
        .at_css(".container .box .item:contains('.#{@file.season_str}') a[href^='/subs']")
      @season_item_cache[path] = item
    end
    item
  end

end

class SubHD
  def initialize(opts)
    @logger = Logger.new($stdout, progname: "SUBHD", datetime_format: "%Y-%m-%d %H:%M:%S")
    @agent = Mechanize.new do |a|
      a.post_connect_hooks << ->(_,_,response,_) do
        response.content_type = 'text/html' if response.content_type.empty?  
      end
    end
    @agent.user_agent_alias = "Mac Safari"
    @season_item_cache = {}
    @force = opts[:force]
  end

  def find(file)
    @file = file
    @agent.get(_base_url)
    unless media_item = _search_item()
      @logger.info "未找到字幕"
      return false 
    end
    media_path = media_item['href']
    @logger.info "---- #{_url(media_path)}"
    if @file.type == '电影'
      sub = @agent.get(media_path).at_css("tr:has(a[href^='/a/'])")
    else
      sub = @agent.get(media_path).at_css("tr:has(a[href^='/a/']):contains('.#{@file.episode_str}')")
    end
    if sub
      @file.sub_name = sub.at_css("a[href^='/a/']").text
      @file.downloads = sub.at_css(">td:nth-last-child(2)").text.strip
      @logger.info "找到 '#{@file.sub_name}', 下载量 #{@file.downloads}"
      @file.download_params = []
      @agent.get(sub.at_css("a[href^='/a/']")["href"]).css("[data-sid]").each do |s|
        @file.download_params << { dasid: s["data-sid"], dafname: s["data-fname"] }
      end
      return true
    else
      @logger.info "未找到字幕"
      return false
    end
  end

  def download
    @file.download_params.map do |sub|
      json = JSON.parse(@agent.post("/ajax/file_ajax", sub).body)
      fname = File.basename(sub[:dafname])
      sub_file = File.join(@file.dir, fname)
      open(sub_file, 'w') { |f| f.write(json["filedata"].gsub(/<br \/>/, '')) } if json["success"]
      fname
    end
  end

  private

  def _base_url
    ENV['SUBHD_URL'] || "https://subhd.tv"
  end

  def _url(path)
    URI.join(_base_url, path).to_s
  end

  def _search_item()
    path = "/search/" + @file.imdb
    if @file.type == '剧集'
      path += " #{@file.season_str}"
      return @season_item_cache[path] if @season_item_cache.has_key?(path)
    end
    resp = nil
    # workaround rate limiting
    loop do
      resp = @agent.get(path)
      break if resp.class == Mechanize::Page
      sleep 5
    end
    item = resp.at_css(".row.no-gutters a[href^='/d/']")
    @season_item_cache[path] = item if @file.type == '剧集'
    item
  end

end

class Subs

  def initialize(opts)
    @logger = Logger.new($stdout, datetime_format: "%Y-%m-%d %H:%M:%S")
    @providers = [ Zimuku.new(opts), SubHD.new(opts) ]
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
      if sub_file.end_with?('.rar')
        %[ unrar e -o+ #{_escape(sub_file)} #{_escape(@file.dir)} ]
      elsif sub_file.end_with?('.zip')
        %x[ 7z e -y -o#{_escape(@file.dir)} -ir\!\*.{ass,srt,sub,idx} #{_escape(sub_file)} ]
      end
    end
  end

  def rename
    if @file.type == '电影'
      Dir["#{_escape(@file.dir)}/*.{sub,idx,ass,srt}"].each do |f|
        _rename_sub(f, @file.filename)
      end
    else
      Dir["#{_escape(@file.dir)}/*{#{@file.episode_str},#{@file.episode_str.downcase}}*.nfo"].each do |nfo|
        prefix = File.basename(nfo).delete_suffix(".nfo")
        Dir.glob("#{_escape(@file.dir)}/*{#{@file.episode_str},#{@file.episode_str.downcase}}*.{sub,idx,ass,srt}", File::FNM_CASEFOLD).each do |f|
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
    lang = lang =~ /(体|文|en|chs|cht|zh|cn|tw)/i ? ".#{lang}" : ""
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

  def _need_processing?
    return false unless @file
    unless @file.imdb
      @logger.warn "#{@file.type} [#{@file.title}], imdb: 未知，略过"
      return false
    end
    existing = Dir["#{_escape(@file.dir)}/#{_escape(@file.filename)}*.{srt,sub,ass}"]
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
