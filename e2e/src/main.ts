// ParkingTrade E2E suite — entry point.
//
//   npm test                      run everything
//   npm test -- --only=booking    run scenarios whose id/title matches
//   npm test -- --keep-data      skip cleanup (for manual inspection)
//   npm test -- --bail           stop after the first failing scenario
//   npm test -- --verbose        extra logging
import { loadConfig } from './config.js'
import { Factory } from './lib/factory.js'
import { Registry } from './lib/registry.js'
import { printSummary, runScenarios, writeReport } from './lib/runner.js'
import { serviceClient } from './lib/supabase.js'

import onboarding from './scenarios/01-building-onboarding.js'
import membership from './scenarios/02-membership-paths.js'
import bulkImport from './scenarios/03-bulk-import.js'
import spots from './scenarios/04-spot-provisioning.js'
import booking from './scenarios/05-booking-lifecycle.js'
import swap from './scenarios/06-swap.js'
import guardrails from './scenarios/07-guardrails.js'
import security from './scenarios/08-security-rls.js'
import concurrency from './scenarios/09-concurrency.js'
import members from './scenarios/10-member-management.js'
import waitlist from './scenarios/11-waitlist.js'
import chat from './scenarios/12-chat-coordination.js'
import waitlistNotify from './scenarios/13-waitlist-notifications.js'
import spotNotify from './scenarios/14-spot-availability-notifications.js'
import joinRequests from './scenarios/15-join-requests.js'
import spotManagement from './scenarios/16-spot-management.js'
import buildingAnnouncements from './scenarios/17-building-announcements.js'
import recurringAvailability from './scenarios/18-recurring-availability.js'
import bookingIssues from './scenarios/19-booking-issues.js'
import buildingScoreboard from './scenarios/20-building-scoreboard.js'

async function main() {
  const cfg = loadConfig()
  console.log(`ParkingTrade E2E — run ${cfg.runId}`)
  console.log(`Target: ${cfg.url}`)

  // Pre-flight: confirm the target is reachable before doing anything.
  try {
    const health = await fetch(`${cfg.url}/auth/v1/health`, { headers: { apikey: cfg.anonKey } })
    if (!health.ok) throw new Error(`auth health endpoint returned ${health.status}`)
  } catch (e: any) {
    console.error(`\n✖ Cannot reach Supabase at ${cfg.url}: ${e?.message ?? e}`)
    console.error('  Is the stack running? For local: `supabase start` + `supabase functions serve`\n')
    process.exit(2)
  }

  const registry = new Registry()
  const f = new Factory(cfg, registry)

  const scenarios = [
    onboarding(f),
    membership(f),
    bulkImport(f),
    spots(f),
    booking(f),
    swap(f),
    guardrails(f),
    security(f),
    concurrency(f),
    members(f),
    waitlist(f),
    chat(f),
    waitlistNotify(f),
    spotNotify(f),
    joinRequests(f),
    spotManagement(f),
    buildingAnnouncements(f),
    recurringAvailability(f),
    bookingIssues(f),
    buildingScoreboard(f),
  ]

  let results
  try {
    results = await runScenarios(scenarios, cfg)
  } finally {
    if (cfg.keepData) {
      console.log(`\n⚠ --keep-data: skipping cleanup. Run \`npm run cleanup\` later to purge E2E data.`)
    } else {
      process.stdout.write('\nCleaning up test data… ')
      const { buildings, users } = await registry.cleanup(serviceClient(cfg))
      console.log(`done (${buildings} buildings, ${users} auth users removed)`)
    }
  }

  const reportFile = writeReport(results, cfg.runId)
  const allGreen = printSummary(results)
  console.log(`Report: ${reportFile}`)
  process.exit(allGreen ? 0 : 1)
}

main().catch((e) => {
  console.error('Fatal error:', e)
  process.exit(2)
})
