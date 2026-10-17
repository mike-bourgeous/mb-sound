FROM docker.io/library/ruby:4.0.7

ARG DEBIAN_FRONTEND=none
RUN apt-get -y update && apt-get -y upgrade && apt-get -y --no-install-recommends install \
	build-essential bash-completion git pkgconf vim less ripgrep jq valgrind \
	libsamplerate0-dev libasound2-dev libjack-jackd2-dev jackd2 ffmpeg graphviz

COPY .bash_aliases /root/.bash_aliases
COPY .bashrc /root/.bashrc

# TODO: Don't copy in tmp/
RUN mkdir /app
COPY . /app
RUN cd /app && bundle install && bundle exec rake clean compile

VOLUME /app
WORKDIR /

# mb-sound: no audio devices in the container
ENV OUTPUT_TYPE=null

# Claude
ENV IS_DEMO=1
# Per-machine config at /claude, with shared folders mounted inside it by
# dock.sh (see the comment at the top of dock.sh).
ENV CLAUDE_CONFIG_DIR=/claude
RUN mkdir -p /claude && curl -fsSL https://claude.ai/install.sh | bash

# GitHub
ENV GH_CONFIG_DIR=/app/.gh-user
RUN mkdir -p /app/.gh-user && \
	wget https://github.com/cli/cli/releases/download/v2.102.0/gh_2.102.0_linux_amd64.deb && \
	dpkg -i gh_2.102.0_linux_amd64.deb && \
	rm gh_2.102.0_linux_amd64.deb

# Git identity for commits made in the container (dock.sh passes the host's
# `git config user.name`/`user.email`; empty means none, as before).  Last so
# a change of identity doesn't rebuild the layers above.
ARG GIT_USER_NAME=
ARG GIT_USER_EMAIL=
RUN if [ -n "$GIT_USER_NAME" ]; then git config --system user.name "$GIT_USER_NAME"; fi && \
	if [ -n "$GIT_USER_EMAIL" ]; then git config --system user.email "$GIT_USER_EMAIL"; fi

WORKDIR /app
CMD /bin/bash
