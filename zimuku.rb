class Zimuku
  attr_accessor :enabled

  def initialize(opts)
    @logger = Logger.new($stdout, progname: "字幕库", datetime_format: "%Y-%m-%d %H:%M:%S")
    @agent = Mechanize.new
    @agent.user_agent_alias = "Windows Edge"
    @agent.max_history = 1
    @season_item_cache = {}
    @force = opts[:force]
    @enabled = true
  end

  def find(file, existing_ids)
    @file = file
    begin
      @agent.get(_base_url, [ ["security_verify_data", "313932302c31323830"] ])
    rescue Mechanize::ResponseCodeError => e
      retry if e.response_code == "404" 
      @logger.warn "无法连接，暂时禁用：#{e.response_code}"
      @enabled = false
      return false
    end
    unless media_item = _search_item()
      @logger.info "未找到字幕"
      return false 
    end
    media_path = media_item['href']
    @logger.info "---- #{_url(media_path)}"
    existing = existing_ids.reject{ |i| i !~ /^zmk-/ }.map{ |i| i.split("-").last }
    if @file.type == '电影'
      subs = @agent
        .get(media_path)
        .css("#subtb > tbody > tr")
        .sort_by {|s| -_download_count(s.at_css(">td:nth-last-child(2)").text) }
    else
      sub_list = @agent.get(media_path).css("#subtb > tbody > tr")
      episode_subs = sub_list
        .select{ |s| s.at_css(":has(a[title*='#{@file.episode_str}']), :has(a[title*='#{@file.episode_str.downcase}'])") }
        .sort_by {|s| - _download_count(s.at_css(">td:nth-last-child(2)").text) }
      season_subs = sub_list
        .select{ |s| s.at_css(":has(a[title*='#{@file.season_str}.']), :has(a[title*='#{@file.season_str.downcase}.'])") }
        .sort_by {|s| - _download_count(s.at_css(">td:nth-last-child(2)").text) }
      subs = episode_subs + season_subs
    end
    sub = subs
      .map { |sub|
        {
          sub_name:       sub.at_css("a[href^='/detail/']")["title"],
          path:           sub.at_css("a[href^='/detail/']")["href"].sub("detail", "dld"),
          download_count: sub.at_css(">td:nth-last-child(2)").text
        }
      }.reject{ |sub|
        existing.any? { |dld_id| sub[:path].include?(dld_id) } 
      }.first
    if sub 
      @file.path = sub[:path]
      @file.id = "zmk-" + @file.path[/\/dld\/(\d+).*/, 1]
      @file.sub_name = sub[:sub_name]
      @file.download_count = sub[:download_count]
      if existing_ids.include?(@file.id)
        @logger.info "已有「#{@file.sub_name}」, 下载量 #{@file.download_count}"
        return false
      else
        @logger.info "找到「#{@file.sub_name}」, 下载量 #{@file.download_count}"
        return true
      end
    else
      @logger.info "未找到新字幕"
      return false
    end
  end

  def download
    links = @agent.get(@file.path)
    link = links.links.first.href
    f = @agent.get(link)
    ext = File.extname(f.header['content-disposition'][/"(.*)"/,1])
    fname = 'zmk-' + File.basename(@file.path, ".html") + ext
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
      # some tv shows may have conflicting names so nfos may end up having '(YYYY)' as part of their
      # names, and this should be removed before performing a search
      path = "/search/?q=" + URI.encode_www_form_component(@file.show_title.sub(/\(\d{4}\)$/, '') + " " + @file.year)
      return @season_item_cache[path] if @season_item_cache.key?(path)
      item = @agent
        .get(path)
        .at_css(".container .box .item:contains('.#{@file.season_str}') a[href^='/subs']")
      @season_item_cache[path] = item
    end
    item
  end

end

