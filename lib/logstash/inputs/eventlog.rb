# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/timestamp"
require "socket"

# This input will pull events from a http://msdn.microsoft.com/en-us/library/windows/desktop/bb309026%28v=vs.85%29.aspx[Windows Event Log].
#
# To collect Events from the System Event Log, use a config like:
# [source,ruby]
#     input {
#       eventlog {
#         type  => 'Win32-EventLog'
#         logfile  => 'System'
#       }
#     }
class LogStash::Inputs::EventLog < LogStash::Inputs::Base

  config_name "eventlog"

  default :codec, "plain"

  # Event Log Name
  config :logfile, :validate => :array, :default => [ "Application", "Security", "System" ]

  public
  def register

    # wrap specified logfiles in suitable OR statements
    @logfiles = @logfile.join("' OR TargetInstance.LogFile = '")

    @hostname = Socket.gethostname
    @logger.info("Registering input eventlog://#{@hostname}/#{@logfile}")

    if RUBY_PLATFORM == "java"
      require "jruby-win32ole"
    else
      require "win32ole"
    end
  end # def register

  public
  def run(queue)

    @wmi = WIN32OLE.connect("winmgmts://")
    wmi_query = "Select * from __InstanceCreationEvent Where TargetInstance ISA 'Win32_NTLogEvent' And (TargetInstance.LogFile = '#{@logfiles}')"

    @logger.debug("Tailing Windows Event Log '#{@logfile}'")

    begin
      @events = @wmi.ExecNotificationQuery(wmi_query)
    rescue => e
      @logger.fatal("Unable to tail Windows Event Log: #{e.message}")
      @logger.info("Windows Event Log Query: #{wmi_query}")
      return # fatal scenario => exit
    end

    loop do

      begin
        # timeout is needed here otherwise NextEvent prevents logstash from exiting
        notification = @events.NextEvent(1000) # 1000 ms
      rescue Java::OrgRacobCom::ComFailException
        next
      end

      event = notification.TargetInstance

      timestamp = to_timestamp(event.TimeGenerated)

      e = LogStash::Event.new(
        "host" => @hostname,
        "path" => @logfile,
        "type" => @type,
        LogStash::Event::TIMESTAMP => timestamp
      )

      %w{Category CategoryString ComputerName EventCode EventIdentifier
          EventType Logfile Message RecordNumber SourceName
          TimeGenerated TimeWritten Type User
      }.each{
          |property| e[property] = event.send property
      }

      if RUBY_PLATFORM == "java"
        # unwrap jruby-win32ole racob data
        e["InsertionStrings"] = unwrap_racob_variant_array(event.InsertionStrings)
        data = unwrap_racob_variant_array(event.Data)
        # Data is an array of signed shorts, so convert to bytes and pack a string
        e["Data"] = data.map{|byte| (byte > 0) ? byte : 256 + byte}.pack("c*")
      else
        # win32-ole data does not need to be unwrapped
        e["InsertionStrings"] = event.InsertionStrings
        e["Data"] = event.Data
      end

      # e["message"] = event.Message

      decorate(e)

      e["insertion"] = parse_insertion(e["message"])
      e["message"] = event.Message.split(Regexp.New('(\\r|\\n|\\t)+')).first

      queue << e

    end # loop

  rescue LogStash::ShutdownSignal
    return
  rescue => ex
    @logger.error("Windows Event Log error: #{ex}\n#{ex.backtrace}")
    sleep 1
    retry
  end # def run

  private
  def unwrap_racob_variant_array(variants)
    variants ||= []
    variants.map {|v| (v.respond_to? :getValue) ? v.getValue : v}
  end # def unwrap_racob_variant_array

  # the event log timestamp is a utc string in the following format: yyyymmddHHMMSS.xxxxxx±UUU
  # http://technet.microsoft.com/en-us/library/ee198928.aspx
  private
  def to_timestamp(wmi_time)
    result = ""
    # parse the utc date string
    /(?<w_date>\d{8})(?<w_time>\d{6})\.\d{6}(?<w_sign>[\+-])(?<w_diff>\d{3})/ =~ wmi_time
    result = "#{w_date}T#{w_time}#{w_sign}"
    # the offset is represented by the difference, in minutes,
    # between the local time zone and Greenwich Mean Time (GMT).
    if w_diff.to_i > 0
      # calculate the timezone offset in hours and minutes
      h_offset = w_diff.to_i / 60
      m_offset = w_diff.to_i - (h_offset * 60)
      result.concat("%02d%02d" % [h_offset, m_offset])
    else
      result.concat("0000")
    end

    return LogStash::Timestamp.new(DateTime.strptime(result, "%Y%m%dT%H%M%S%z").to_time)
  end

  #parse message field for key => insertion string
  def parse_insertion(message)
    delimiter = Regexp.new('(\\r|\\n|\\t)+')
    child = nil
    parent = nil
    previous_child = true
    insertion = Hash.new
    parsed = message.split(delimiter)

    parsed.each do |part|
      if not part.match(delimiter)
        if /\:/.match(part) and not parent and previous_child
          parent = part
          previous_child = false
        elsif /\:/.match(part) and parent and not previous_child
          child = part
          previous_child = true
        elsif /\:/.match(part) and parent and previous_child
          parent = child
          child = part
        elsif not /\:/.match(part) and child and previous_child
          insertion[parent] = insertion[parent].nil? ? { child => part } : insertion[parent].merge(child => part)
          previous_child = false
        end
      end
    end
    return insertion
  end

end # class LogStash::Inputs::EventLog

