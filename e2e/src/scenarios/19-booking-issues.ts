// Scenario 19 — Booking issues (no-show / trust reports):
//   party-gated kinds, report window, outsider rejection, admin resolve,
//   outbox enqueue + service-role drain. Completing an approved booking
//   still requires end_time + 2h (grace).
import { scenario } from '../lib/runner.js'
import type { Factory } from '../lib/factory.js'
import { hoursFromNow } from '../lib/factory.js'
import { eq, expect, expectStatus, ok } from '../lib/assert.js'
import { buildWorld, type World } from './world.js'

type IssueRow = { id: string; kind: string; status: string }

export default (f: Factory) =>
  scenario('booking-issues', 'Booking issues — report, authz, resolve, notify', async (t) => {
    let w: World
    await t.step('setup: building with 3 resident apartments + spots', async () => {
      w = await buildWorld(f, 'Issue', 3)
    })

    const lender = () => w.apartments[0]
    const borrower = () => w.apartments[1]
    const outsider = () => w.apartments[2]

    let bookingId = ''
    await t.step('insert an in-window approved booking (service role)', async () => {
      const row = ok(
        await f.svc
          .from('booking_requests')
          .insert({
            spot_id: lender().spotId,
            borrower_apartment_id: borrower().apartmentId,
            lender_apartment_id: lender().apartmentId,
            created_by_profile_id: borrower().resident.id,
            start_time: hoursFromNow(-1).toISOString(),
            end_time: hoursFromNow(2).toISOString(),
            status: 'approved',
          })
          .select('id')
          .single(),
        'insert in-window approved booking',
      ) as { id: string }
      bookingId = row.id
    })

    await t.step('outsider cannot report', async () => {
      const res = await outsider().resident.client.rpc('report_booking_issue', {
        p_booking_id: bookingId,
        p_kind: 'borrower_did_not_arrive',
      })
      expect(res.error, 'uninvolved apartment must not report')
    })

    await t.step('borrower cannot file a lender-only kind', async () => {
      const res = await borrower().resident.client.rpc('report_booking_issue', {
        p_booking_id: bookingId,
        p_kind: 'borrower_did_not_arrive',
      })
      expect(res.error, 'borrower must not file borrower_did_not_arrive')
    })

    let issueId = ''
    await t.step('lender reports borrower_did_not_arrive', async () => {
      const res = await lender().resident.client.rpc('report_booking_issue', {
        p_booking_id: bookingId,
        p_kind: 'borrower_did_not_arrive',
        p_notes: 'Nobody showed',
      })
      expect(!res.error, `report_booking_issue failed: ${res.error?.message}`)
      const row = res.data as IssueRow
      issueId = row.id
      eq(row.kind, 'borrower_did_not_arrive', 'kind echoed')
      eq(row.status, 'open', 'fresh issue is open')
    })

    await t.step('duplicate open report from the same apartment is rejected', async () => {
      const res = await lender().resident.client.rpc('report_booking_issue', {
        p_booking_id: bookingId,
        p_kind: 'borrower_overstay',
      })
      expect(res.error, 'second open report from the same apartment must fail')
    })

    await t.step('borrower can still file the borrower-side kind on the same booking', async () => {
      const res = await borrower().resident.client.rpc('report_booking_issue', {
        p_booking_id: bookingId,
        p_kind: 'lender_did_not_vacate',
      })
      expect(!res.error, `borrower report failed: ${res.error?.message}`)
      eq((res.data as IssueRow).status, 'open', 'borrower report is open')
    })

    await t.step('RLS 049: building admin (not a party) can SELECT the booking; outsider and foreign admin cannot', async () => {
      const adminView = ok(
        await w.building.admin.client.from('booking_requests').select('id').eq('id', bookingId),
        'admin select booking',
      ) as unknown[]
      eq(adminView.length, 1, 'building admin should see the booking')

      const outsiderView = ok(
        await outsider().resident.client.from('booking_requests').select('id').eq('id', bookingId),
        'outsider select booking',
      ) as unknown[]
      eq(outsiderView.length, 0, 'non-party resident must not see the booking')

      const other = await f.createBuilding('Issue-Select-Other')
      const foreignView = ok(
        await other.admin.client.from('booking_requests').select('id').eq('id', bookingId),
        'foreign admin select booking',
      ) as unknown[]
      eq(foreignView.length, 0, 'foreign admin must not see the booking')
    })

    await t.step('RLS: outsider cannot see the issue; admin can', async () => {
      const hidden = ok(
        await outsider().resident.client.from('booking_issues').select('id').eq('id', issueId),
        'outsider select',
      ) as unknown[]
      eq(hidden.length, 0, 'outsider must not see the issue')

      const adminView = ok(
        await w.building.admin.client.from('booking_issues').select('id').eq('id', issueId),
        'admin select',
      ) as unknown[]
      eq(adminView.length, 1, 'building admin should see the issue')
    })

    await t.step('resident cannot resolve; admin can uphold', async () => {
      const denied = await lender().resident.client.rpc('resolve_booking_issue', {
        p_issue_id: issueId,
        p_action: 'upheld',
      })
      expect(denied.error, 'non-admin must not resolve')

      const okRes = await w.building.admin.client.rpc('resolve_booking_issue', {
        p_issue_id: issueId,
        p_action: 'upheld',
        p_notes: 'Camera confirms',
      })
      expect(!okRes.error, `resolve failed: ${okRes.error?.message}`)
      eq((okRes.data as IssueRow).status, 'upheld', 'issue should be upheld')
    })

    await t.step('foreign admin cannot resolve the remaining open issue', async () => {
      const other = await f.createBuilding('Issue-Other')
      const open = ok(
        await f.svc.from('booking_issues').select('id, status')
          .eq('booking_id', bookingId)
          .eq('status', 'open')
          .single(),
        'remaining open issue',
      ) as { id: string }
      const res = await other.admin.client.rpc('resolve_booking_issue', {
        p_issue_id: open.id,
        p_action: 'dismissed',
      })
      expect(res.error, 'foreign admin must not resolve')
    })

    await t.step('outbox has reported + resolved rows; drain is service-role only', async () => {
      const rows = ok(
        await f.svc.from('booking_issue_notifications')
          .select('issue_id, event, status')
          .eq('issue_id', issueId),
        'read outbox',
      ) as Array<{ event: string; status: string }>
      const events = rows.map((r) => r.event).sort()
      expect(events.includes('reported'), 'reported outbox row')
      expect(events.includes('resolved'), 'resolved outbox row')

      const asUser = await f.edge('notify-booking-issue', lender().resident, { issue_id: issueId })
      expectStatus(asUser, 403, 'resident JWT must not drain the outbox')

      const drain = await f.edgeAsService('notify-booking-issue', { issue_id: issueId, event: 'reported' })
      expectStatus(drain, 200, 'service-role drain should succeed')
    })

    await t.step('report window: booking that ended >24h ago is rejected', async () => {
      const past = ok(
        await f.svc
          .from('booking_requests')
          .insert({
            spot_id: lender().spotId,
            borrower_apartment_id: borrower().apartmentId,
            lender_apartment_id: lender().apartmentId,
            created_by_profile_id: borrower().resident.id,
            start_time: hoursFromNow(-48).toISOString(),
            end_time: hoursFromNow(-30).toISOString(),
            status: 'completed',
          })
          .select('id')
          .single(),
        'insert stale completed booking',
      ) as { id: string }
      const res = await lender().resident.client.rpc('report_booking_issue', {
        p_booking_id: past.id,
        p_kind: 'borrower_did_not_arrive',
      })
      expect(res.error, 'report after end_time + 24h must fail')
    })

    await t.step('complete_expired_bookings waits 2 hours after end_time', async () => {
      const recent = ok(
        await f.svc
          .from('booking_requests')
          .insert({
            spot_id: lender().spotId,
            borrower_apartment_id: borrower().apartmentId,
            lender_apartment_id: lender().apartmentId,
            created_by_profile_id: borrower().resident.id,
            start_time: hoursFromNow(-4).toISOString(),
            end_time: hoursFromNow(-1.5).toISOString(),
            status: 'approved',
          })
          .select('id')
          .single(),
        'insert recently-ended approved booking',
      ) as { id: string }
      const { error } = await f.svc.rpc('complete_expired_bookings')
      expect(!error, `complete_expired_bookings failed: ${error?.message}`)
      eq((await f.getBooking(recent.id))!.status, 'approved', 'end_time + 1.5h is still inside the 2h grace')
    })
  })
