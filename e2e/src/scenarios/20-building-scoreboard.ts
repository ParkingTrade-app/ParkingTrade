// Scenario 20 — Building scoreboard (Roadmap 2.1, migration 050).
//
//   A. Score math — completed lend (+10) + hours lent (+1/h).
//   B. Open / dismissed booking_issues do not change the score.
//   C. Upheld issues penalise the accused apartment (−5), not the reporter.
//   D. Reciprocal completed swap (+15 each side, plus the lend/hours).
//   E. Cross-building RPC is rejected (42501).
//   F. Direct SELECT on apartment_scores is denied (view is RPC-only).
import { scenario } from '../lib/runner.js'
import type { Factory } from '../lib/factory.js'
import { hoursFromNow } from '../lib/factory.js'
import { eq, expect, ok } from '../lib/assert.js'
import { buildWorld, type World } from './world.js'

type LeaderRow = {
  apartment_id: string
  apartment_identifier: string
  completed_lends: number | string
  hours_lent: number | string
  swaps_completed: number | string
  upheld_issues: number | string
  score: number | string
  rank: number | string
}

const n = (v: number | string): number => Number(v)

export default (f: Factory) =>
  scenario('building-scoreboard', 'Building scoreboard — math, penalties, isolation', async (t) => {
    let w: World
    await t.step('setup: building with 3 resident apartments + spots', async () => {
      w = await buildWorld(f, 'Score', 3)
    })

    const lender = () => w.apartments[0]
    const borrower = () => w.apartments[1]
    const spectator = () => w.apartments[2]

    const board = async (): Promise<LeaderRow[]> => {
      const rows = ok(
        await lender().resident.client.rpc('get_building_leaderboard', {
          p_building_id: w.building.buildingId,
        }),
        'get_building_leaderboard',
      ) as LeaderRow[]
      expect(Array.isArray(rows), 'leaderboard must return an array')
      return rows
    }

    const rowFor = (rows: LeaderRow[], apartmentId: string): LeaderRow => {
      const hit = rows.find((r) => r.apartment_id === apartmentId)
      expect(hit, `leaderboard missing apartment ${apartmentId}`)
      return hit!
    }

    // Exact durations so hour-points are integers (avoid Date.now() drift).
    const lendStart = hoursFromNow(-1)
    const lendEnd = new Date(lendStart.getTime() + 4 * 3_600_000)
    const swapStart = hoursFromNow(10)
    const swapEnd = new Date(swapStart.getTime() + 2 * 3_600_000)

    let oneWayId = ''
    await t.step('insert a 4-hour completed one-way lend (service role)', async () => {
      const row = ok(
        await f.svc
          .from('booking_requests')
          .insert({
            spot_id: lender().spotId,
            borrower_apartment_id: borrower().apartmentId,
            lender_apartment_id: lender().apartmentId,
            created_by_profile_id: borrower().resident.id,
            start_time: lendStart.toISOString(),
            end_time: lendEnd.toISOString(),
            status: 'completed',
          })
          .select('id')
          .single(),
        'insert completed one-way lend',
      ) as { id: string }
      oneWayId = row.id
    })

    await t.step('completed lend scores +10 and +1 per hour (4h → 14)', async () => {
      const rows = await board()
      const L = rowFor(rows, lender().apartmentId)
      const B = rowFor(rows, borrower().apartmentId)
      const S = rowFor(rows, spectator().apartmentId)

      eq(n(L.completed_lends), 1, 'lender completed_lends')
      eq(n(L.hours_lent), 4, 'lender hours_lent')
      eq(n(L.swaps_completed), 0, 'lender swaps before swap pair')
      eq(n(L.upheld_issues), 0, 'lender upheld_issues')
      eq(n(L.score), 14, 'lender score = 10 + 4')

      eq(n(B.completed_lends), 0, 'borrower has no lends')
      eq(n(B.score), 0, 'borrower score is 0 before penalty')
      eq(n(S.score), 0, 'spectator score is 0 before swap')
      eq(n(L.rank), 1, 'lender is rank 1')
    })

    let issueId = ''
    await t.step('open issue does not change scores', async () => {
      const res = await lender().resident.client.rpc('report_booking_issue', {
        p_booking_id: oneWayId,
        p_kind: 'borrower_did_not_arrive',
        p_notes: 'No-show for scoreboard',
      })
      expect(!res.error, `report_booking_issue failed: ${res.error?.message}`)
      issueId = (res.data as { id: string }).id

      const L = rowFor(await board(), lender().apartmentId)
      const B = rowFor(await board(), borrower().apartmentId)
      eq(n(L.score), 14, 'open issue must not credit the reporter')
      eq(n(B.score), 0, 'open issue must not penalise the accused')
      eq(n(B.upheld_issues), 0, 'open issue is not upheld')
    })

    await t.step('dismissed issue still does not penalise', async () => {
      const res = await w.building.admin.client.rpc('resolve_booking_issue', {
        p_issue_id: issueId,
        p_action: 'dismissed',
        p_notes: 'false alarm',
      })
      expect(!res.error, `dismiss failed: ${res.error?.message}`)

      const B = rowFor(await board(), borrower().apartmentId)
      eq(n(B.score), 0, 'dismissed issue must not penalise')
      eq(n(B.upheld_issues), 0, 'dismissed issue is not counted')
    })

    await t.step('upheld issue applies −5 to the accused borrower, not the reporter', async () => {
      const reported = await lender().resident.client.rpc('report_booking_issue', {
        p_booking_id: oneWayId,
        p_kind: 'borrower_did_not_arrive',
      })
      expect(!reported.error, `second report failed: ${reported.error?.message}`)
      const secondId = (reported.data as { id: string }).id

      const upheld = await w.building.admin.client.rpc('resolve_booking_issue', {
        p_issue_id: secondId,
        p_action: 'upheld',
        p_notes: 'confirmed no-show',
      })
      expect(!upheld.error, `uphold failed: ${upheld.error?.message}`)

      const rows = await board()
      const L = rowFor(rows, lender().apartmentId)
      const B = rowFor(rows, borrower().apartmentId)
      eq(n(L.score), 14, 'reporter score unchanged by uphold')
      eq(n(L.upheld_issues), 0, 'reporter is not the accused')
      eq(n(B.upheld_issues), 1, 'borrower has one upheld issue')
      eq(n(B.score), -5, 'borrower score = −5')
    })

    await t.step('reciprocal completed swap adds +15 each side plus lend/hours', async () => {
      ok(
        await f.svc.from('booking_requests').insert([
          {
            spot_id: spectator().spotId,
            borrower_apartment_id: lender().apartmentId,
            lender_apartment_id: spectator().apartmentId,
            created_by_profile_id: lender().resident.id,
            start_time: swapStart.toISOString(),
            end_time: swapEnd.toISOString(),
            status: 'completed',
          },
          {
            spot_id: lender().spotId,
            borrower_apartment_id: spectator().apartmentId,
            lender_apartment_id: lender().apartmentId,
            created_by_profile_id: spectator().resident.id,
            start_time: swapStart.toISOString(),
            end_time: swapEnd.toISOString(),
            status: 'completed',
          },
        ]),
        'insert reciprocal completed swap',
      )

      const rows = await board()
      const L = rowFor(rows, lender().apartmentId)
      const S = rowFor(rows, spectator().apartmentId)
      const B = rowFor(rows, borrower().apartmentId)

      // Lender: original 4h lend + swap 2h lend + swap bonus = 10+4 + 10+2 + 15 = 41
      eq(n(L.completed_lends), 2, 'lender now has two completed lends')
      eq(n(L.hours_lent), 6, 'lender hours 4+2')
      eq(n(L.swaps_completed), 1, 'lender counted in the swap pair')
      eq(n(L.score), 41, 'lender score after swap')

      // Spectator: 2h lend + swap bonus = 10+2+15 = 27
      eq(n(S.completed_lends), 1, 'spectator one completed lend')
      eq(n(S.hours_lent), 2, 'spectator hours')
      eq(n(S.swaps_completed), 1, 'spectator counted in the swap pair')
      eq(n(S.score), 27, 'spectator score after swap')

      eq(n(B.score), -5, 'borrower penalty unchanged by the swap')
      eq(n(L.rank), 1, 'lender still rank 1')
      eq(n(S.rank), 2, 'spectator rank 2')
    })

    await t.step('cross-building query is blocked', async () => {
      const other = await buildWorld(f, 'ScoreX', 1)
      const denied = await other.apartments[0].resident.client.rpc('get_building_leaderboard', {
        p_building_id: w.building.buildingId,
      })
      expect(denied.error, 'foreign resident must not read another building leaderboard')

      const own = ok(
        await other.apartments[0].resident.client.rpc('get_building_leaderboard', {
          p_building_id: other.building.buildingId,
        }),
        'own-building leaderboard should succeed',
      ) as LeaderRow[]
      expect(own.some((r) => r.apartment_id === other.apartments[0].apartmentId),
        'own building must include the caller apartment')
    })

    await t.step('direct SELECT on apartment_scores is denied', async () => {
      const leaked = await lender().resident.client.from('apartment_scores').select('*')
      expect(leaked.error, 'authenticated must not SELECT apartment_scores directly')
    })
  })
