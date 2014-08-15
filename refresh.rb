#!/usr/bin/env ruby
# encoding: utf-8

require 'pp'
require 'open-uri'
require 'nokogiri'
require 'fileutils'
require 'erb'
require 'net/http'
require 'uri'
require 'json'
require 'nkf'
require 'levenshtein'

@rarities = %w{N HN R HR SR}
@regions = %w{Vo Da Vi Ex}

class Hash
  def safe_invert
    inject({}) { |h,(k,v)| (h[v] ||= []) << k; h }
  end
end

@rules = Hash.new {|hash, key| key}
@rules.merge!(Hash[[('ａ'..'ｚ').to_a+('Ａ'..'Ｚ').to_a,('a'..'z').to_a+('A'..'Z').to_a].transpose])
@rules.merge!({
  "　"=>" ",
  "("=>"（",
  ")"=>"）",
  "／"=>"/",
  "､"=>"、",
  '　'=>' ',
  '-'=>'ー',
  '!'=>'！',
  '?'=>'？',
  '='=>'＝'
})

def get_cardlist
  base_url = 'http://www.millionlive.com/index.php?'
  directory = './tmp/'

  FileUtils.remove_entry_secure(directory) if File.exist?('tmp')
  Dir.mkdir('tmp') unless File.exist?('tmp')

  @rarities.each do |rarity|
    filename = "rarity_#{rarity}.html"
    filepath = directory + filename
    url = base_url + rarity

    open(url) do |src|
      open(filepath, "w") do |dst|
        dst.write src.read
      end
    end
  end
end

def parse_cardlist
  directory = './tmp/'

  @regions.product(@rarities).map{|a|a.join('_')}.each do |path|
    FileUtils.remove_entry_secure(path, true)
  end

  @rarities.each do |rarity|
    filename = "rarity_#{rarity}.html"
    filepath = directory + filename

    html = Nokogiri::HTML(open(filepath))
    list = html.search('#main_content').children.search('h3, li')
    h_elem_positions = list.search('h3').collect{|h| list.index(h)}

    region = ''

    list.each_with_index do |item, index|
      if h_elem_positions.include? index
        region = item.text.match(/^[a-zA-Z]{2}/)
        Dir.mkdir("./tmp/#{region}_#{rarity}") unless File.exist?("./tmp/#{region}_#{rarity}")
      else
        next if region === ''
        tmp_filename = "%03d "%[index] + item.children[0].text + ".html"
        dir_to_save = "./tmp/#{region}_#{rarity}/"
        path_to_save = dir_to_save + tmp_filename
        next if item.children[0].attributes['href'].nil?
        url = item.children[0].attributes['href'].value

        puts path_to_save

        retry_count = 0
        begin
          open(url) do |src|
            open(path_to_save, "w") do |dst|
              puts dst.write src.read
            end
          end
        rescue
          retry if (retry_count += 1) < 5
        end
      end
    end
  end
end

def get_idhash
  id_hash = JSON.parse(Net::HTTP.get URI.parse('https://gist.githubusercontent.com/berlysia/9225421/raw/gistfile1.json'))

  id_hash.each do |k,v|
    id_hash[k] = NKF::nkf('-WwXm0', v).gsub(/[-=　!\?]/,@rules)
  end

  id_hash = id_hash.invert

  id_hash.each do |k,v|
    id_hash[k] = v.to_i
  end
end

=begin
  1bit: 13 "他Pフェス参加時、" 有無
  3bit: 12,11,10 対象属性VoDaVi
  1bit: 9 味方1,敵0
  3bit: 8,7,6 010(フロント対象),111(自分のみ)
  2bit: 5,4 APDP 1/0
  1bit: 3 up/down 1/0
  3bit: 2,1,0 小(1)->特大(4)
  全14bit
=end
def parse_skill(str)

  ret = ""
  ret += str.match("他Pフェス参加時、") ? "1" : "0"

  if matched = str.match(/((?:Vo|Da|Vi)属性敵?|全カード|全ての敵|自分)の/)
    if ["全カード","自分"].include?(matched[1])
      ret += "1111"
    elsif matched[1] === "全ての敵"
      ret += "1110"
    else
      ret += if matched[1].include?("Vo") then "1" else "0" end
      ret += if matched[1].include?("Da") then "1" else "0" end
      ret += if matched[1].include?("Vi") then "1" else "0" end
      ret += if matched[1].include?("敵") then "0" else "1" end
    end
  end

  if str.match("自分の")
    ret += "111"
  else
    ret += "010"
  end

  ret += str.match("AP") ? "1" : "0"
  ret += str.match("DP") ? "1" : "0"

  ret += str.match("アップ") ? "1" : "0"

  if matched = str.match("（(特大|大|中|小)）")
    case matched[1]
    when "特大"
      ret += "100"
    when "大"
      ret += "011"
    when "中"
      ret += "010"
    when "小"
      ret += "001"
    end
  end

  ret.to_i(2)
end

def create_csv
  dir_list = (['Vo','Da','Vi','Ex'].product ['N','HN','R','HR','SR']).map{|p|p.join('_')}
  base_name = 'millionlive_'

  # csvが持つキーとその順序
  keylist = [
    "カードID","属性", "レア度", "カード名", "アイドル名", "コスト", "LVMAX",
    "AP", "DP", "MAX AP", "MAX DP", "スキル", "効果", "入手手段",
    "ポーズ追加", "売却価格", "親愛度上限", "詳細",
    "(AP+DP)/cost","AP/DP", "DP/AP", "AP/(AP+DP)", "DP/(AP+DP)"
  ]

  id_hash = get_idhash

  # 現行のファイル削除
  Dir.glob('./**.csv').each do |path|
    FileUtils.remove_entry_secure(path)
  end

  dir_list.each do |dirname|
    csv_base = []
    filelist = Dir.glob('./tmp/'+dirname+'/*.html')
    region, rarity = dirname.split('_')

    filelist.each do |filepath|
      card_base = {}
      card_base['属性'] = region
      card_base['レア度'] = rarity
      puts filepath
      html = Nokogiri::HTML(open(filepath))
      html.search('tbody')[0].search('tr:not(:first-child)')[0...12].each do |row|
        next if row.children.size < 2
        key = row.children[0].text
        value = row.children[1].text.gsub(/[()､　／ａ-ｚＡ-Ｚ]/,@rules)
        unless keylist.include?(key)
          if ["入手場所(ガシャ/覚醒等)","排出されるガチャ"].include?(key)
            key = "入手手段"
          else
            puts "#{key}: not found in keylist"
            next
          end
        end
        card_base[key] = value
        if key === 'カード名'
          card_base['アイドル名'] = value.split(/[\s]/)[-1]
          card_base['カードID'] = id_hash[card_base[key]]
          unless card_base['カードID']
            estimated = ''
            nearest = Float::INFINITY

            id_hash.each_key do |hash_key|
              distance = Levenshtein.distance(hash_key, card_base['カード名'])
              if distance < nearest && distance <= 3
                estimated = hash_key
                nearest = distance
              end
            end

            puts "#{card_base['カード名']} : それっぽいキーがありませんでした" if estimated.size == 0

            card_base['カードID'] = id_hash[estimated] if estimated
          end
        end
      end

      card_base['詳細']||=""

      # pp card_base

      csv_base << card_base
    end

    csv_string = ""

    # json output
    json_filename = base_name + dirname + '.json'
    json_base = Hash[[csv_base.map{|i|i["カードID"]},csv_base.map{|i|
      j=Marshal.load(Marshal.dump(i))
      ["排出されるガチャ","売却価格","親愛度上限","詳細","入手場所(ガシャ/覚醒等)","ポーズ追加"].map{|k|j.delete(k) if j.has_key?(k)}
      j["skill_serialized"] = parse_skill(j["効果"])
      j
      }].transpose]
    open(json_filename, 'w') do |output|
      puts output.write JSON.pretty_generate(json_base)
    end

    # csv output
    csv_base.each do |item|
      item['AP+DP'] = item['MAX AP'].to_i + item['MAX DP'].to_i
      item['(AP+DP)/cost'] = "%.2f"%[(item['AP+DP'].to_f)/item['コスト'].to_f]
      item['AP/DP'] = "%.2f"%[(item['MAX AP'].to_f / item['MAX DP'].to_f)]
      item['DP/AP'] = "%.2f"%[(item['MAX DP'].to_f / item['MAX AP'].to_f)]
      item['AP/(AP+DP)'] = "%.2f"%[(item['MAX AP'].to_f / item['AP+DP'].to_f)]
      item['DP/(AP+DP)'] = "%.2f"%[(item['MAX DP'].to_f / item['AP+DP'].to_f)]

      keylist.each do |key|
        if item[key].class == Float
          csv_string += "%.2f,"%[item[key]]
        else
          csv_string += "#{item[key]},"
        end
      end
      csv_string.gsub!(/,$/,"\n")
    end

    csv_filename = base_name + dirname + '.csv'
    open(csv_filename, 'w') do |output|
      puts output.write csv_string
    end


  end
end
