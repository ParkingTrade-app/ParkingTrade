// Scenario 18 — Recurring availability is expanded in SQL (migration 046):
//   booking must overlap an expanded occurrence; waitlist matches a *future*
//   weekday of a weekly template (not just the anchor window); waiters who
//   join after publish are matched by match_waitlist_against_upcoming_availability.
import { scenario } from '../lib/runner.js'
import type { Factory } from '../lib/factory.js'
import { hoursFromNow } from '../lib/factory.js'
import { eq, expect, expectStatus, ok } from '../lib/assert.js'
import { buildWorld, type World } from './world.js'

/** Next UTC calendar date whose ISO day-of-week is `isoDow` (1=Mon … 7=Sun). */
function nextUtcWeekday(isoDow: number, hour: number, minute: number, weeksAhead = 1): Date {
  const now = new Date()
  const jsDay = now.getUTCDay() // 0=Sun
  const currentIso = jsDay === 0 ? 7 : jsDay
  let delta = isoDow - currentIso
  if (delta <= 0) delta += 7
  delta += 7 * (weeksAhead - 1)
  return new Date(Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate() + delta,
    hour,
    minute,
    0,
  ))
}

const ISO_TO_CODE = ['', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'] as const

export default (f: Factory) =>
  scenario('recurring-availability', 'Recurring availability — SQL expand, book, waitlist', async (t) => {
    let w: World
    await t.step('setup: building with 2 resident apartments + spots', async () => {
      w = await buildWorld(f, 'Recur', 2)
    })

    const lender = () => w.apartments[0]
    const borrower = () => w.apartments[1]

    const targetIso = 2 // Tuesday — any weekday is fine; pick one that is stable
    const occStart = nextUtcWeekday(targetIso, 10, 0, 1)
    const occEnd = nextUtcWeekday(targetIso, 12, 0, 1)
    const until = new Date(occStart.getTime() + 60 * 24 * 3600 * 1000)
    const pattern = JSON.stringify({
      type: 'weekly',
      days: [ISO_TO_CODE[targetIso]],
      until: until.toISOString(),
    })

    await t.step('booking a window with no overlapping period is rejected', async () => {
      await f.publishAvailability(lender().resident, lender().spotId, hoursFromNow(1), hoursFromNow(3))
      const res = await f.requestBooking(borrower().resident, lender().spotId, hoursFromNow(10), hoursFromNow(12))
      expectStatus(res, 400, 'request outside every period must be rejected')
    })

    let periodId = ''
    await t.step('lender publishes a weekly template anchored on the upcoming weekday', async () => {
      const row = ok(
        await lender().resident.client.from('spot_availability_periods').insert({
          spot_id: lender().spotId,
          start_time: occStart.toISOString(),
          end_time: occEnd.toISOString(),
          is_recurring: true,
          recurring_pattern: pattern,
        }).select('id').single(),
        'recurring template insert should pass RLS',
      ) as { id: string }
      periodId = row.id
      expect(periodId, 'period id missing')
    })

    await t.step('expand_availability_occurrences returns the upcoming weekday instance', async () => {
      const from = new Date(occStart.getTime() - 12 * 3600 * 1000)
      const to = new Date(occEnd.getTime() + 12 * 3600 * 1000)
      const { data, error } = await f.svc.rpc('expand_availability_occurrences', {
        p_spot_id: lender().spotId,
        p_from: from.toISOString(),
        p_to: to.toISOString(),
      })
      expect(!error, `expand rpc failed: ${error?.message}`)
      const hits = ((data as Array<{ period_id: string; start_time: string }>) ?? [])
        .filter((r) => r.period_id === periodId)
      expect(hits.length >= 1, 'expander should emit the weekly occurrence')
    })

    await t.step('borrower can book a window that overlaps the expanded occurrence', async () => {
      const res = await f.requestBooking(borrower().resident, lender().spotId, occStart, occEnd)
      expectStatus(res, 200, 'booking overlapping a weekly occurrence should succeed')
    })

    // ── Waitlist: join AFTER publish, then backfill ──────────
    let lateEntryId = ''
    await t.step('waiter joining after publish stays waiting until the backfill RPC', async () => {
      const occ2Start = nextUtcWeekday(targetIso, 10, 0, 2)
      const occ2End = nextUtcWeekday(targetIso, 12, 0, 2)
      const row = ok(
        await borrower().resident.client.from('spot_waitlist').insert({
          spot_id: lender().spotId,
          requester_apartment_id: borrower().apartmentId,
          created_by_profile_id: borrower().resident.id,
          desired_start: occ2Start.toISOString(),
          desired_end: occ2End.toISOString(),
        }).select('id, status').single(),
        'waitlist insert after recurring publish',
      ) as { id: string; status: string }
      lateEntryId = row.id
      eq(row.status, 'waiting', 'insert trigger already fired; late waiter must still be waiting')
    })

    await t.step('match_waitlist_against_upcoming_availability matches the late waiter', async () => {
      const { data, error } = await f.svc.rpc('match_waitlist_against_upcoming_availability')
      expect(!error, `backfill rpc failed: ${error?.message}`)
      expect((data as number) >= 1, `backfill should match at least one entry, got ${data}`)
      const row = ok(
        await f.svc.from('spot_waitlist').select('status').eq('id', lateEntryId).single(),
        'read late waitlist entry',
      ) as { status: string }
      eq(row.status, 'matched', 'late waiter should be matched against a future weekly occurrence')
    })
  })
