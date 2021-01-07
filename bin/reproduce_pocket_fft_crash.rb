#!/usr/bin/env ruby

require 'bundler/setup'
require 'numo/pocketfft'

def dc_input_small(ndim)
  Numo::DFloat.ones(*([10] * ndim))
end

def dc_input_large(ndim)
  Numo::DFloat.ones(*([64] * ndim))
end

def assert(value, expected)
  raise "Expected #{expected}, got #{value}" if value != expected
end

def fft(data)
  case data.ndim
  when 1
    Numo::Pocketfft.fft(data) / data.length
  when 2
    Numo::Pocketfft.fft2(data) / data.length
  else
    Numo::Pocketfft.fftn(data) / data.length
  end
end

[1, 4, 3, 2].each do |ndim|
  puts "#{ndim} dimensions"

  dc1 = dc_input_small(ndim)
  dc2 = dc_input_large(ndim)

  puts "Small #{dc1.length}"

  assert(fft(dc1)[*([0] * ndim)].real.round(5), 1)
  assert(fft(dc1)[*([1] * ndim)].real.round(5), 0)
  assert(fft(dc1)[*([0] * ndim)].imag.round(5), 0)
  assert(fft(dc1)[*([1] * ndim)].imag.round(5), 0)
  assert(fft(dc1).sum.real.round(5), 1)
  assert(fft(dc1).sum.imag.round(5), 0)

  puts "Large #{dc2.length}"

  assert(fft(dc2)[*([0] * ndim)].real.round(5), 1)
  assert(fft(dc2)[*([1] * ndim)].real.round(5), 0)
  assert(fft(dc2)[*([0] * ndim)].imag.round(5), 0)
  assert(fft(dc2)[*([1] * ndim)].imag.round(5), 0)
  assert(fft(dc2).sum.real.round(5), 1)
  assert(fft(dc2).sum.imag.round(5), 0)
end
