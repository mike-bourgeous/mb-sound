module MB
  module Sound
    # Prints a value class's own #inspect through pp (sd-ux-fixes-1, the
    # review's #6): Pry prints results with pp, and Data's and Struct's
    # #pretty_print ignore a class's #inspect, so `design :bass, ...`
    # printed an 11-line `#<data ...Opened ...>` instead of its documented
    # one line.  Included by every Data or Struct class in lib/ that
    # defines #inspect (spec/lib/mb/sound/one_line_print_spec.rb lists the
    # ones that don't, with why).
    module OneLinePrint
      def pretty_print(q)
        q.text(inspect)
      end
    end
  end
end
