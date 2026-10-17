# Records examples that grow the process's resident memory by more than
# RssReport::THRESHOLD_MB (rake spec:parallel sets MB_SOUND_RSS_REPORT to a
# JSON path per process and lists them after the slowest examples).  Slow
# examples show in times; a memory hog shows here, before it slows the
# other processes (a monitor_trim_spec example once grew a worker to 22 GB;
# see design/notes/audio_io.md).  Growth that a later example reuses (the
# first big allocation of a process) is listed too; look for repeats.
module RssReport
  THRESHOLD_MB = 200

  @records = []

  class << self
    attr_reader :records

    # Resident memory in MB (Linux; nil elsewhere).
    def rss_mb
      File.read('/proc/self/status')[/^VmRSS:\s+(\d+)/, 1]&.to_i&./(1024)
    rescue SystemCallError
      nil
    end
  end
end

if (path = ENV['MB_SOUND_RSS_REPORT'])
  RSpec.configure do |config|
    config.around(:each) do |example|
      before = RssReport.rss_mb
      example.run
      after = RssReport.rss_mb
      if before && after && after - before > RssReport::THRESHOLD_MB
        RssReport.records << { 'example' => example.location, 'description' => example.full_description, 'grew_mb' => after - before, 'rss_mb' => after }
      end
    end

    config.after(:suite) do
      File.write(path, JSON.generate(RssReport.records))
    end
  end
end
