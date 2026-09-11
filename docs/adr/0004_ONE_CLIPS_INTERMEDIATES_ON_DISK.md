# Keep one clip's ProRes intermediates on disk at a time

One clip's baseline plus master is 4.6GB; across 18 clips that is ~83GB against 63GB free, on top
of the 24GB of source already on disk. Keeping every clip's intermediates does not fit. Policy: a
clip's intermediates live only while that clip is being worked on — review, proofs, sign-off — and
are deleted once it is approved. The finals (~100–170MB each) and the untouched source are the
only things kept per clip long-term.

## Considered options

**Delete immediately after each export** was rejected deliberately. A master takes 10–15 minutes to
regenerate, so deleting it the moment finals exist turns any later "nudge the curve slightly" into
a 10–15 minute wait before you can see anything. Holding it through the sign-off loop costs nothing
extra — it is still one clip's worth of disk — and keeps iteration fast where iteration happens.

## Consequences

Re-grading a finished clip means regenerating its baseline and master from source through the
stage scripts first. That is cheap in disk and costs render time only, which is the right way
round. It is also why nothing downstream may ever re-grade from a delivered MP4.
