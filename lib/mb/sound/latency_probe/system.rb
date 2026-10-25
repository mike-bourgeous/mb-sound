module MB
  module Sound
    class LatencyProbe
      # Whole-machine readings sampled once a second by the consumer thread
      # (never the probe thread): free memory, load average, CPU busy and
      # steal percentages, and on Linux pressure stall information (PSI),
      # major page faults, memory compaction stalls, and CPU frequency.
      #
      # Linux reads /proc (in a container: the VM's or host's view, which is
      # what matters for VM stalls); macOS uses FastLatency.system_sample
      # (getloadavg, host CPU ticks, host_statistics64 like vm_stat).  Each
      # #sample returns a Hash of the columns in COLUMNS that are known
      # (rates and percentages from the change since the last sample).
      class System
        COLUMNS = %i[
          mem_available_mb mem_total_mb load1 cpu_busy_pct cpu_steal_pct cpu_iowait_pct
          psi_cpu_some_ms psi_mem_some_ms psi_mem_full_ms psi_io_some_ms
          major_faults compact_stalls cpu_mhz swap_out
        ].freeze

        LINUX = File.readable?('/proc/stat')

        def initialize(frequency_every: 5)
          @last_cpu = nil
          @last_psi = {}
          @last_vm = nil
          @frequency_every = frequency_every
          @samples = 0
          @mhz = nil
          @psi = LINUX && File.readable?('/proc/pressure/cpu')
        end

        # True if PSI (/proc/pressure) is readable.
        def psi?
          @psi
        end

        def sample
          @samples += 1
          LINUX ? linux : other
        rescue SystemCallError, IOError
          {}
        end

        private

        def linux
          out = {}

          mem = File.read('/proc/meminfo')
          out[:mem_available_mb] = mem[/^MemAvailable:\s+(\d+)/, 1].to_i / 1024.0
          out[:mem_total_mb] = mem[/^MemTotal:\s+(\d+)/, 1].to_i / 1024.0

          out[:load1] = File.read('/proc/loadavg').split.first.to_f

          # cpu  user nice system idle iowait irq softirq steal guest guest_nice
          cpu = File.foreach('/proc/stat').first.split.drop(1).map(&:to_i)
          if @last_cpu
            d = cpu.zip(@last_cpu).map { |a, b| a - b }
            total = d[0..7].sum
            if total > 0
              idle = d[3] + d[4]
              out[:cpu_busy_pct] = 100.0 * (total - idle) / total
              out[:cpu_iowait_pct] = 100.0 * d[4] / total
              out[:cpu_steal_pct] = 100.0 * d[7].to_i / total
            end
          end
          @last_cpu = cpu

          if @psi
            out[:psi_cpu_some_ms] = psi_delta(:cpu, 'some')
            out[:psi_mem_some_ms] = psi_delta(:memory, 'some')
            out[:psi_mem_full_ms] = psi_delta(:memory, 'full')
            out[:psi_io_some_ms] = psi_delta(:io, 'some')
          end

          vm = {}
          File.foreach('/proc/vmstat') do |line|
            k, v = line.split
            vm[k] = v.to_i if k == 'pgmajfault' || k == 'compact_stall' || k == 'pswpout'
          end
          if @last_vm
            out[:major_faults] = vm['pgmajfault'].to_i - @last_vm['pgmajfault'].to_i
            out[:compact_stalls] = vm['compact_stall'].to_i - @last_vm['compact_stall'].to_i
            out[:swap_out] = vm['pswpout'].to_i - @last_vm['pswpout'].to_i
          end
          @last_vm = vm

          @mhz = mean_mhz if @mhz.nil? || @samples % @frequency_every == 0
          out[:cpu_mhz] = @mhz if @mhz

          out.compact
        end

        # Milliseconds stalled since the last sample from /proc/pressure/<kind>.
        def psi_delta(kind, line)
          text = File.read("/proc/pressure/#{kind}")
          total = text[/^#{line} .*total=(\d+)/, 1]
          return nil unless total

          key = :"#{kind}_#{line}"
          us = total.to_i
          last = @last_psi[key]
          @last_psi[key] = us
          last && (us - last) / 1000.0
        rescue SystemCallError
          nil
        end

        def mean_mhz
          mhz = File.read('/proc/cpuinfo').scan(/^cpu MHz\s*:\s*([\d.]+)/).flatten.map(&:to_f)
          mhz.empty? ? nil : mhz.sum / mhz.length
        rescue SystemCallError
          nil
        end

        def other
          s = FastLatency.system_sample
          out = { load1: s[:load1] }
          if s[:mem_available]
            out[:mem_available_mb] = s[:mem_available] / 1048576.0
            out[:mem_total_mb] = s[:mem_total] / 1048576.0 if s[:mem_total]
          end
          if s[:cpu_idle]
            cpu = s.values_at(:cpu_user, :cpu_system, :cpu_nice, :cpu_idle)
            if @last_cpu
              d = cpu.zip(@last_cpu).map { |a, b| a - b }
              total = d.sum
              out[:cpu_busy_pct] = 100.0 * (total - d[3]) / total if total > 0
            end
            @last_cpu = cpu
          end
          if s[:swapouts]
            if @last_vm
              out[:major_faults] = s[:pageins] - @last_vm[:pageins]
              out[:swap_out] = s[:swapouts] - @last_vm[:swapouts]
            end
            @last_vm = s.slice(:pageins, :swapouts)
          end
          out.compact
        end
      end
    end
  end
end
