export const meta = {
  name: 'board-digest',
  description: 'Readers summarize where each changed issue and pull request stands; the orchestrator keeps only the lines',
  whenToUse: 'After scripts/board/read.sh reports changed items. Pass its batches as args: {batches: [["path", ...], ...]}. Returns one line per item to pipe into scripts/board/digest.sh save.',
  phases: [
    { title: 'Read', detail: 'one light reader per batch of item files', model: 'haiku' },
  ],
}

// The orchestrator scouts first: it runs read.sh, which fetches the full
// text of the changed items to disk and prints the batches. This workflow
// only fans the reading out, so no body or comment ever enters the
// orchestrator's context. Each reader returns structured lines.

const LINES = {
  type: 'object',
  properties: {
    items: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          number: { type: 'integer' },
          ball: { type: 'string', enum: ['owner', 'agent', 'reviewer', 'service', 'nobody'] },
          next: { type: 'string' },
          blocker: { type: 'string' },
          summary: { type: 'string' },
        },
        required: ['number', 'ball', 'next', 'blocker', 'summary'],
      },
    },
  },
  required: ['items'],
}

const batches = (args && args.batches) || []
if (!batches.length) {
  log('No batches were passed; nothing to read.')
  return { lines: [] }
}

const prompt = (paths) => `Read each of these files in full. Each holds one issue or pull request: its body, its last comments, and for a pull request its reviews.

${paths.map((p) => '- ' + p).join('\n')}

For each file, say where the item stands right now, from what the text says, not from its title or labels:
- ball: who must act next. "owner" if a question or decision for the project owner is open and unanswered. "agent" if the work can proceed, including when the owner has answered. "reviewer" if a pull request waits on review. "service" if it waits on something outside the project. "nobody" if nothing is asked of anyone.
- next: the next concrete step, in at most twelve words.
- blocker: what stops it, in at most ten words, or "-" if nothing does.
- summary: one sentence: what is asked, what was decided, and the latest thing that happened with who said it.
The newest comment outranks the body and the labels. Do not guess; if the text does not say, say "not stated". Return one entry per file, with the number from the file name.`

phase('Read')
const results = await parallel(batches.map((paths, i) => () =>
  agent(prompt(paths), { label: `read batch ${i + 1}`, phase: 'Read', schema: LINES, model: 'haiku', effort: 'low' })))

const read = results.filter(Boolean)
if (read.length < batches.length) log(`${batches.length - read.length} batch(es) returned nothing; their items stay marked as changed and are read next time.`)

const lines = read.flatMap((r) => r.items).map((it) =>
  `${it.number} | ${it.ball} | ${it.next} | ${it.blocker} | ${it.summary}`.replace(/[\t\r\n]+/g, ' '))
return { lines }
