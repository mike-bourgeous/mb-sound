require 'mkmf'

with_cflags("#{$CFLAGS} -O3 -Wall -Wextra #{ENV['EXTRACFLAGS']} -std=c99 -D_XOPEN_SOURCE=700 -D_ISOC99_SOURCE -D_GNU_SOURCE") do
  create_makefile('mb/fast_sound')
end
