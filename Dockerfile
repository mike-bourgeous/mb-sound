FROM docker.io/library/ruby:3.4

ENV DEBIAN_FRONTEND=none
RUN apt-get -y update && apt-get -y upgrade && apt-get -y --no-install-recommends install libsamplerate-dev libjack-dev build-essential gnuplot

RUN mkdir /mb-sound
COPY . /mb-sound
WORKDIR /mb-sound

RUN bundle install && rake clean compile

CMD /bin/bash
