// job-controller.js — Index now: one job at a time; states and counts exactly as the
// engine reported (the vanilla app.js pollJob/index-btn logic carried over verbatim).
// The poll loop answers a failed fetch honestly (the S1 lesson: a dead promise froze
// the job line and left "indexing…" in the footer forever), repeated busy-clicks poll
// ONE loop per live job (the dedupe token), and a finished crawl re-reads the status
// and the index list so the panel shows the targets that exist NOW.
export function createJobController({ api, store, refreshStatus, loadAccess, pollMs = 2000 }) {
  const seq = { jobPoll: null };

  async function pollJob(id) {
    for (;;) {
      let job;
      try {
        // A failed poll (server restarting, engine mid-respawn 503, network) used to reject
        // the loop's promise unhandled: the thread of polling DIED, the job line froze at
        // its last state, and "indexing…" stayed in the footer forever — no retry, no
        // honest error. Say what happened, clear the indexing state, stop.
        job = (await api(`/api/v1/jobs/${id}`)).job;
      } catch (error) {
        store.set({ job: { state: "interrupted", text: `job poll failed: ${error.message}` },
                     indexing: null });
        seq.jobPoll = null;
        return;
      }
      showJob(job);
      if (["done", "interrupted", "busy"].includes(job.state)) {
        refreshStatus();
        loadAccess();   // a finished crawl moves the engine's numbers: re-read the
        return;         // index list so the panel shows the targets that exist now
      }
      await new Promise((resolve) => setTimeout(resolve, pollMs));
    }
  }

  function showJob(job) {
    const indexing = ["queued", "running"].includes(job.state) ? job : null;
    if (!indexing) seq.jobPoll = null;      // finished: a later 409 may poll afresh
    const counts = [job.state,
      job.searchable !== null && job.searchable !== undefined ? `searchable ${job.searchable}/${job.files}` : null,
      job.pending ? `pending ${job.pending}` : null,
      job.vectors ? `vectors ${job.vectors}` : null,
      job.files_done ? `indexed ${job.files_done}` : null,
      job.seconds !== undefined ? `${job.seconds} s` : null,
      job.why].filter(Boolean);
    store.set({ job: { state: job.state, text: counts.join(" · ") }, indexing });
  }

  async function indexNow(prune) {
    const pruneFlag = Boolean(prune);       // engine --prune: retire rows of files no longer in the folders
    try {
      const {job} = await api("/api/v1/index", {method: "POST", body: JSON.stringify({prune: pruneFlag})});
      store.set({ job: { state: "queued", text: `job ${job.id} queued` } });
      seq.jobPoll = job.id;
      pollJob(job.id);
    } catch (error) {
      if (error.status === 409) {
        const live = error.message.match(/job ([0-9a-f]+)/);   // answered busy: poll the live one
        if (live && live[1] !== seq.jobPoll) {                 // repeated clicks used to stack
          seq.jobPoll = live[1];                               // a second polling loop on the
          pollJob(live[1]);                                    // same live id — one loop per job
        }
        store.set({ job: { state: "running", text: "busy — a job is already running" } });
      } else {
        store.set({ job: { state: "interrupted", text: `index request failed: ${error.message}` } });
      }
    }
  }

  return { indexNow, pollJob, get jobPoll() { return seq.jobPoll; } };
}
