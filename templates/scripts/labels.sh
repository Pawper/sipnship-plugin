#!/bin/sh
# Create the labels the templates rely on. Safe to run again; existing labels
# are updated in place. Needs gh, signed in, run inside the repository.
# The seven state labels match the seven values of the board's State field.
set -e
mk() { gh label create "$1" --color "$2" --description "$3" --force >/dev/null && echo "label $1"; }
mk "state:ready"              "0E8A16" "Can be picked up now"
mk "state:in-progress"        "1D76DB" "An agent is on it"
mk "state:waiting-on-owner"   "FBCA04" "Needs a decision or input from the project owner"
mk "state:waiting-on-service" "D93F0B" "Blocked on an outside service"
mk "state:parked"             "C5DEF5" "Deliberately set aside"
mk "state:dated"              "BFD4F2" "Has a date it must happen on or by"
mk "state:after-launch"       "E4E669" "Not before the launch"
mk "task"                     "EDEDED" "One unit of work for one agent"
mk "ci-red"                   "B60205" "Opened by CI when the full run on main fails"
mk "state:blocked"            "5319E7" "Stopped by something outside the issue; the comment says what"
mk "audit"                    "EDEDED" "The tracking issue the nightly audit comments on"
mk "drive"                    "EDEDED" "The issue where project-drive posts proposals and reads approvals"
