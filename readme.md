## Subs 简单中文字幕下载器

默认从字幕库下载，SubHD作为补充（已失效）

```
./subs.rb <目录>
```

### 使用须知

- 这个脚本依赖于p7zip，unrar可执行文件和Ruby mechanize gem。

- 脚本靠从nfo文件里读取imdb号码来搜索字幕，对文件名和目录结构有要求。

  + imdb号必须已经在nfo文件中。
  + 电影的nfo文件必须与电影同名。
  + 剧集的文件名必须含有S0XE0X字样。

- 已有字幕的nfo文件会被跳过，可以用`-f`来强制下载。

### docker镜像

docker镜像启动时会自动执行，然后每2小时执行一遍。数据需要挂载在`/data`。


```
  subs:
    image: roylez/subs
    restart: always
    volumes:
      - /media:/data
```

### 环境变量

```
SUBS_FORCE      # 强制下载，默认 0
SUBS_INTERVAL   # 检查间隔，默认 7200 (2小时)
ZIMUKU_URL      # 字幕库URL，默认 https://zimuku.org
SUBHD_URL       # SUBHD URL，默认 https://subhd.tv
TZ              # 时区，默认 Asia/Hong_Kong
```
