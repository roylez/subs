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
      sub = @agent.get(media_path).at_css(".row:has(a[href^='/a/'])")
    else
      sub = @agent.get(media_path).at_css(".row:has(a[href^='/a/']):contains('.#{@file.episode_str}')")
    end
    if sub
      @file.sub_name = sub.at_css("a[href^='/a/']").text
      @file.download_count = sub.at_css(".row>div:nth-child(2)").text.strip
      @logger.info "找到 '#{@file.sub_name}', 下载量 #{@file.download_count}"
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
    item = resp.at_css(".row > div > a[href^='/d/']")
    @season_item_cache[path] = item if @file.type == '剧集'
    item
  end

end

