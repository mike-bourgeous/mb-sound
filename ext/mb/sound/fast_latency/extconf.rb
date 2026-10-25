require 'mkmf'

# A system latency probe (see fast_latency.c): pthreads only, no NArray or
# shared headers.  C11 for stdatomic.h (the lock-free ring and counters).
# Linux needs librt for clock_nanosleep on older glibc (a no-op on newer).
have_library('pthread')
have_library('rt', 'clock_nanosleep') unless RUBY_PLATFORM.include?('darwin')

with_cflags("#{$CFLAGS} -O2 -ggdb3 -Wall -Wextra -Werror -Wno-unused-parameter #{ENV['EXTRACFLAGS']} -std=c11") do
  create_makefile('mb/sound/fast_latency')
end
