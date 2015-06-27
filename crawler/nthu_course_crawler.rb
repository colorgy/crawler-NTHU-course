require 'crawler_rocks'
require 'iconv'

require 'rtesseract'
require 'open-uri'

require 'json'
require 'pry'

require_relative './nthu_note_pattern.rb'

class NthuCourseCrawler
  include CrawlerRocks::DSL
  include NthuNotePattern

  DAYS = {
    "M" => 1,
    "T" => 2,
    "W" => 3,
    "R" => 4,
    "F" => 5,
    "S" => 6
  }

  PERIODS = {
    "1" => 1,
    "2" => 2,
    "3" => 3,
    "4" => 4,
    "5" => 5,
    "6" => 6,
    "7" => 7,
    "8" => 8,
    "9" => 9,
    "a" => 10,
    "b" => 11,
    "c" => 12,
  }

  def initialize year: current_year, term: current_term, update_progress: nil, after_each: nil, params: nil

    @query_url = "https://www.ccxp.nthu.edu.tw/ccxp/INQUIRE/JH/6/6.2/6.2.3/JH623001.php"
    @result_url = "https://www.ccxp.nthu.edu.tw/ccxp/INQUIRE/JH/6/6.2/6.2.3/JH623002.php"

    @year = params && params["year"].to_i || year
    @term = params && params["term"].to_i || term
    @update_progress_proc = update_progress
    @after_each_proc = after_each

    @ic = Iconv.new("utf-8//translit//IGNORE","big5")
  end

  def courses detail: false
    @detail = detail
    @courses = {}

    visit @query_url

    depts = @doc.css('select[name="DEPT"] option').map {|opt| [opt[:value], opt.text]}
    depts_h = Hash[depts[1..-1].map {|dept| [dept[0], dept[1].strip.split('-')[1].match(/(^.+?[^\w])[\w\-\s&\.\(\)\']+$/)[1]]}]

    @name_to_code = Hash[depts_h.map{|k, v| [v, k.strip]}]
    # ys = "#{@year-1911}|#{@term.to_s.ljust(2, '0')}"

    # fetch captcha, keep trying until correct captcha
    loop do
      @captcha = refresh_captcha

      r = RestClient.post @result_url, {
        'ACIXSTORE' => @acixstore,
        'T_YEAR' => (@year-1911).to_s,
        'C_TERM' => @term.to_s.ljust(2, '0'),
        'E_YEAR' => nil,
        'CATEGORY' => nil,
        'STU_CLASS' => nil,
        'STU_GROUP' => nil,
        'SEL_FUNC' => 'DEP',
        'DEPT' => 'ANTH',
        'auth_num' => @captcha
      }

      break if not r.to_s.include?('Wrong check code!')
    end # end loop do

    # 拿到 auth_num 及對應 acixstore，可以開始招搖撞騙了
    depts_h.keys.each do |dep_c|
      puts depts_h[dep_c]
      r = RestClient.post @result_url, {
        'ACIXSTORE' => @acixstore,
        'T_YEAR' => (@year-1911).to_s,
        'C_TERM' => @term.to_s.ljust(2, '0'),
        'E_YEAR' => nil,
        'CATEGORY' => nil,
        'STU_CLASS' => nil,
        'STU_GROUP' => nil,
        'SEL_FUNC' => 'DEP',
        'DEPT' => dep_c,
        'auth_num' => @captcha
      }

      parse_course(Nokogiri::HTML(@ic.iconv(r)), dep_c, depts_h[dep_c])
    end

    @courses.map{|k, v| v}
  end

  def refresh_captcha
    visit @query_url

    @acixstore = get_view_state["ACIXSTORE"]

    image_url = URI.join(@query_url, @doc.css('img')[0][:src]).to_s
    File.write("tmp/#{@acixstore}.png", open(image_url).read)
    img = RTesseract.new("tmp/#{@acixstore}.png", psm: 8, options: :digits)

    return img.to_s.strip
  end

  def parse_course(doc, dep_c, dep_n)
    doc.css('div.newpage').each do |page|
      year = nil; term = nil; department = nil; department_code = nil; class_code = nil;

      page.css('font').first.text.match(/(?<year>\d+)學年度第(?<term>\d)學期(?<dep>.+?)\((?<dc>[A-Z]+)\s*(?<gc>.+?)\)課程/) do |m|
        year = m[:year]
        term = m[:term]
        department = m[:dep]
        department_code = m[:dc]
        grade_code = m[:gc]
        class_code = "#{department_code}#{grade_code}"
      end

      year ||= @year-1911; term ||= @term; department ||= dep_n; department_code ||= dep_c

      page.css('tr:not(:first-child)').each do |row|
        datas = row.css('td')

        lecturer = datas[5].text.strip.gsub(/\ /,'')
        lecturer = (lecturer.scan(/^[^A-Za-z0-9]+/).first unless lecturer.scan(/^[^A-Za-z0-9]+/).empty?)
        lecturer && lecturer.gsub!(/ /, '') && lecturer.gsub!(/ /, '')

        # normalize location
        course_days = []
        course_periods = []
        course_locations = []
        datas[4].search('br').each {|br| br.replace("\n")}
        location = datas[4].text.strip.split("\n")[0]
        datas[3].text.scan(/([#{DAYS.keys.join('|')}])([#{PERIODS.keys.join('|')}])/).each do |pss|
          # [["R", "6"], ["R", "7"], ["R", "8"]]
          course_days << DAYS[pss[0]]
          course_periods << PERIODS[pss[1]]
          course_locations << location
        end

        if @detail
          # TODOs: parse syllabus page
          # "https://www.ccxp.nthu.edu.tw/ccxp/INQUIRE/JH/common/Syllabus/1.php?ACIXSTORE=#{acixstore}&c_key=#{URI.encode(code)}")
        end

        general_code = datas[0].text.gsub(/\s+/, '')

        code = "#{year}#{term.to_s.ljust(2, '0')}#{general_code}-#{class_code}"

        @courses[code] || @courses[code] = {}
        @courses[code] = {
          year: year,
          term: term,
          name: datas[1].text.strip.gsub(/\s+/, ' '),
          code: code,
          general_code: general_code,
          credits: datas[2].text.strip.to_i,
          lecturer: lecturer,
          # notes: notes,
          required: datas[7] && datas[7].text.include?('必'),
          department: department,
          department_code: "#{department_code}#{class_code}",
          day_1: course_days[0],
          day_2: course_days[1],
          day_3: course_days[2],
          day_4: course_days[3],
          day_5: course_days[4],
          day_6: course_days[5],
          day_7: course_days[6],
          day_8: course_days[7],
          day_9: course_days[8],
          period_1: course_periods[0],
          period_2: course_periods[1],
          period_3: course_periods[2],
          period_4: course_periods[3],
          period_5: course_periods[4],
          period_6: course_periods[5],
          period_7: course_periods[6],
          period_8: course_periods[7],
          period_9: course_periods[8],
          location_1: course_locations[0],
          location_2: course_locations[1],
          location_3: course_locations[2],
          location_4: course_locations[3],
          location_5: course_locations[4],
          location_6: course_locations[5],
          location_7: course_locations[6],
          location_8: course_locations[7],
          location_9: course_locations[8],
        }
        @after_each_proc.call(:course => @courses[code]) if @after_each_proc
      end # each row do
    end # each newpage do
  end # end parse_course


  def current_year
    (Time.now.month.between?(1, 7) ? Time.now.year - 1 : Time.now.year)
  end

  def current_term
    (Time.now.month.between?(2, 7) ? 2 : 1)
  end

end

# cc = NthuCourseCrawler.new(year: 2015, term: 1)
# File.write('1041courses.json', JSON.pretty_generate(cc.courses))
