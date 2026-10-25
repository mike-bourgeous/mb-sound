require 'csv'
require 'json'

module MB
  module Sound
    class LatencyProbe
      # A LatencyProbe run read back from its directory (seconds.csv,
      # events.csv, histograms.json, meta.json), with the reader methods
      # Report uses, so a run that crashed or was saved earlier can be
      # reported and plotted again: `LatencyProbe.load(dir)`, then
      # `Report.new(saved).text` or `saved.save(dir)`.
      class Saved
        attr_reader :dir, :options, :stats, :episodes, :ruby_events, :session_events, :meta

        def initialize(dir)
          @dir = dir
          @meta = JSON.parse(File.read(File.join(dir, 'meta.json')), symbolize_names: true)
          @options = @meta[:options] || {}
          @stats = (@meta[:probe] || {}).dup
          @rows = read_seconds
          @hists = read_histograms
          events = read_events
          @episodes = events.select { |e| e[:kind] == :episode }
          @ruby_events = events.select { |e| e[:source] == :ruby }
          @session_events = events.select { |e| e[:source] == :session }
          @stats[:episodes] = @episodes.length if @stats[:episodes].to_i < @episodes.length
        end

        def seconds
          @rows
        end

        def elapsed
          @meta[:seconds].to_f
        end

        def yjit?
          !!@meta[:yjit]
        end

        def session_watch
          nil
        end

        def top
          @episodes.max_by(50) { |e| e[:stall_ns] }
        end

        def histogram(kind = :stall)
          @hists[kind] || Histogram.new
        end

        # Writes the report and plots again (into the run's directory by
        # default).  Returns the Hash of paths.
        def save(dir = @dir, formats: %w[svg png txt])
          Report.new(self).save(dir, formats: formats)
        end

        def report
          Report.new(self).text
        end

        private

        def number(v)
          return nil if v.nil? || v.empty?
          return Integer(v) if v.match?(/\A-?\d+\z/)

          Float(v)
        rescue ArgumentError
          v
        end

        def read_seconds
          path = File.join(@dir, 'seconds.csv')
          return [] unless File.exist?(path)

          CSV.foreach(path, headers: true).map { |r| r.to_h.to_h { |k, v| [k.to_sym, number(v)] } }
        end

        def read_histograms
          path = File.join(@dir, 'histograms.json')
          return {} unless File.exist?(path)

          data = JSON.parse(File.read(path))
          max = data.delete('max') || {}
          data.to_h { |k, pairs|
            counts = Array.new(Histogram::BUCKETS, 0)
            pairs.each { |floor, c| counts[Histogram.bucket(floor)] += c }
            [k.to_sym, Histogram.new(counts, max: max[k])]
          }
        end

        def read_events
          path = File.join(@dir, 'events.csv')
          return [] unless File.exist?(path)

          ns = ->(ms) { ms.nil? ? nil : (ms * 1e6).round }
          CSV.foreach(path, headers: true).map { |r|
            h = r.to_h.to_h { |k, v| [k.to_sym, k == 'source' || k == 'kind' || k == 'time' || k == 'detail' ? v : number(v)] }
            wall = (h[:wall] * 1e9).round
            e = {
              source: h[:source].to_sym, kind: h[:kind].to_sym, wall_ns: wall,
              worst_wall_ns: h[:worst_wall] ? (h[:worst_wall] * 1e9).round : wall,
              stall_ns: ns.(h[:stall_ms]) || 0, late_ns: ns.(h[:late_ms]) || 0, mem_ns: ns.(h[:mem_ms]) || 0,
              cpu_ns: ns.(h[:cpu_ms]) || 0, duration_ns: ns.(h[:duration_ms]) || 0, ticks: h[:ticks] || 0,
              over: h[:over] || 0, missed: h[:missed] || 0, cpu: h[:cpu] || -1, mem_thread_cpu_ns: ns.(h[:mem_thread_cpu_ms]) || 0,
            }
            # (files from before the over/missed/worst_wall columns kept
            # them in the detail text)
            if (d = h[:detail]).is_a?(String)
              d.scan(/(\w+) (-?[\d.]+)/) { |k, v| e[k.to_sym] ||= number(v) if %w[over missed cpu].include?(k) && e[k.to_sym].to_i <= 0 }
              e[:over] = d[/over (\d+)/, 1].to_i if e[:over] == 0 && d.include?('over ')
              e[:missed] = d[/missed (\d+)/, 1].to_i if e[:missed] == 0 && d.include?('missed ')
              e[:count] = d[/count (\d+)/, 1].to_i if e[:kind] == :underrun
            end
            e
          }
        end
      end
    end
  end
end
