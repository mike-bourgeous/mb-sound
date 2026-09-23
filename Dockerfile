FROM docker.io/library/ruby:4.0.3

ARG DEBIAN_FRONTEND=none
RUN apt-get -y update && apt-get -y upgrade && apt-get -y --no-install-recommends install \
	build-essential bash-completion git pkgconf vim less ripgrep jq sqlite3 chromium \
	chromium-driver fonts-liberation postgresql-17 libpq-dev

COPY .bash_aliases /root/.bash_aliases
COPY .bashrc /root/.bashrc

RUN mkdir /app
COPY . /app
RUN cd /app && bundle install

VOLUME /app
WORKDIR /

# Claude
ENV IS_DEMO=1
ENV CLAUDE_CONFIG_DIR=/app/.claude-user
RUN mkdir -p /app/.claude-user && curl -fsSL https://claude.ai/install.sh | bash

# GitHub
ENV GH_CONFIG_DIR=/app/.gh-user
RUN mkdir -p /app/.gh-user && \
	wget https://github.com/cli/cli/releases/download/v2.96.0/gh_2.96.0_linux_amd64.deb && \
	dpkg -i gh_2.96.0_linux_amd64.deb && \
	rm gh_2.96.0_linux_amd64.deb

# ngrok
RUN wget https://bin.ngrok.com/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz && \
	tar -xvzf ngrok-v3-stable-linux-amd64.tgz -C /usr/local/bin && \
	rm ngrok-v3-stable-linux-amd64.tgz

WORKDIR /app
CMD /bin/bash
