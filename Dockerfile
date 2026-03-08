FROM docker.io/library/ruby:3.4

ARG DEBIAN_FRONTEND=none
RUN apt-get -y update && apt-get -y upgrade && apt-get -y --no-install-recommends install libsamplerate-dev libjack-dev build-essential gnuplot bash-completion git pkgconf vim ffmpeg graphviz less

COPY .bash_aliases /root/.bash_aliases
COPY .bashrc /root/.bashrc

RUN mkdir /mb-sound
RUN --mount=type=bind,source=.,destination=/mb-sound cd /mb-sound && bundle install

VOLUME /mb-sound

WORKDIR /
ENV IS_DEMO=1
RUN curl -fsSL https://claude.ai/install.sh | bash

WORKDIR /mb-sound
CMD /bin/bash
