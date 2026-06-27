#!/bin/sh
# Run once after cloning to configure git filters.
git config filter.strip-team.clean "sed '/DEVELOPMENT_TEAM/d'"
echo "Git filters configured."
