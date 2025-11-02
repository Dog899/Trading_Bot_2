#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require "uri"
require "net/http"
require "rss"

TICKERS = (ENV["SYMBOLS"] || "NVDA,META,TSM,FCX,MA").split(",").map(&:strip).uniq
LOOKBACK_HOURS = (ENV["LOOKBACK_HOURS"] || "12").to_i # headlines window
LANG   = ENV["NEWS_LANG"] || "en-US"
REGION = ENV["NEWS_REGION"] || "US"

# --- lightweight lexicon (tweak freely) ---
POS = %w[beat beats raises raised upgrade upgrades upgraded guidance\ up record\ revenue record\ profit wins win contract\ award partnership approval approved secures bullish]
NEG = %w[miss misses cuts cut downgrade downgraded guidance\ cut warns warning lawsuit probe investigation breach recall bearish strike halt delays delay layoffs layoff]

TOPIC_BOOSTS = {
  /guidance\s+up|raises guidance|beat[s]?/i => +0.4,
  /upgrade|upgraded/i                       => +0.25,
  /contract|award|secures/i                 => +0.2,
  /lawsuit|probe|investigation|breach/i     => -0.4,
  /guidance\s+cut|warns|warning/i           => -0.5,
  /downgrade|downgraded/i                   => -0.3,
  /strike|halt|recall|layoff/i              => -0.3
}

def google_news_rss(ticker, hours)
  q = URI.encode_www_form_component("#{ticker} stock")
  URI("https://news.google.com/rss/search?q=#{q}%20when:#{hours}h&hl=#{LANG}&gl=#{REGION.split('-').last}&ceid=#{REGION}:#{LANG.split('-').last}")
end

def http_get(uri)
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = "event-swing-bot/1.0"
    res = http.request(req)
    raise "HTTP #{res.code} for #{uri}" unless res.is_a?(Net::HTTPSuccess)
    res.body
  end
end

def score_headline(title)
  t = title.downcase
  s = 0.0
  POS.each { |w| s += 1.0 if t.include?(w) }
  NEG.each { |w| s -= 1.0 if t.include?(w) }
  # clamp to [-1, +1]
  [[s, 1.0].min, -1.0].max
end

def topic_boost(title)
  TOPIC_BOOSTS.each { |re, v| return v if title =~ re }
  0.0
end

def source_of(item)
  # Google News RSS often includes source element; fallback to link host
  src = item.respond_to?(:source) && item.source ? item.source.content.to_s : nil
  return src unless (src.nil? || src.empty?)
  begin
    host = URI(item.link).host
    host && host.sub(/^www\./, "")
  rescue
    "unknown"
  end
end

now = Time.now.utc
results = []

TICKERS.each do |sym|
  begin
    uri = google_news_rss(sym, LOOKBACK_HOURS)
    rss = RSS::Parser.parse(http_get(uri), false)
    items = rss&.items || []
    items.select! do |it|
      pub = it.pubDate || it.dc_date || now
      (now - Time.parse(pub.to_s)) <= LOOKBACK_HOURS * 3600
    end

    # dedupe by title
    uniq_items = {}
    items.each { |it| uniq_items[it.title.to_s.strip] ||= it }
    items = uniq_items.values

    sentiments = []
    sources = []
    boosts = 0.0
    items.each do |it|
      title = it.title.to_s
      sentiments << score_headline(title)
      boosts += topic_boost(title)
      sources << source_of(it)
    end

    s1 = if sentiments.empty?
           0.0
         else
           # EW mean toward recent
           alpha = 2.0 / [10.0, sentiments.size.to_f + 1.0].max
           m = 0.0
           sentiments.each { |v| m = alpha * v + (1 - alpha) * m }
           m
         end

    s3 = sources.uniq.size # publisher diversity 0..N
    nf = 0.5 * s1 + 0.3 * [s3 / 5.0, 1.0].min + 0.2 * [[boosts, 1.0].min, -1.0].max
    nf = [[nf, 1.0].min, -1.0].max

    signal =
      if nf <= -0.4
        "RISK_OFF"    # avoid new longs / consider tighten stops
      elsif nf >= 0.6
        "BUY"         # pro-tailwind (size up in your main bot if aligned)
      else
        "NEUTRAL"
      end

    results << {
      ticker: sym,
      now_utc: now.iso8601,
      items: items.size,
      unique_sources: s3,
      s1_sentiment: s1.round(3),
      topic_boost: boosts.round(2),
      news_factor: nf.round(3),
      signal: signal
    }
  rescue => e
    warn "[ERR] #{sym}: #{e}"
    results << { ticker: sym, error: e.message, signal: "NEUTRAL" }
  end
end

# Write artifact & pretty print
Dir.mkdir("results") unless Dir.exist?("results")
File.write("results/signals.json", JSON.pretty_generate(results))
puts "=== Event Swing Signals (last #{LOOKBACK_HOURS}h) ==="
results.each do |r|
  if r[:error]
    puts "#{r[:ticker]}: ERROR #{r[:error]}"
  else
    puts "#{r[:ticker]}  items=#{r[:items]} src=#{r[:unique_sources]} NF=#{r[:news_factor]}  → #{r[:signal]}"
  end
end
puts "Saved results/signals.json"
