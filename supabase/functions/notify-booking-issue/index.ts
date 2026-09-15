// Booking-Trust — push when a booking issue is reported or resolved.
//
// Drains booking_issue_notifications (migration 047). Service-role only.
// Pass {"issue_id": "...", "event": "reported"|"resolved"} to deliver one
// row (webhook path), or no body to drain the backlog.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4'
import { sendPushToUser } from '../_shared/push.ts'

const serve = Deno.serve

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MAX_ATTEMPTS = 5
const BATCH_SIZE = 50

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

const KIND_LABEL: Record<string, string> = {
  lender_did_not_vacate: 'spot still occupied',
  borrower_did_not_arrive: 'borrower did not arrive',
  borrower_overstay: 'borrower overstayed',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    const token = (req.headers.get('Authorization') ?? '').replace('Bearer ', '')
    if (!serviceRoleKey || token !== serviceRoleKey) {
      return json({ error: 'Forbidden — service role key required' }, 403)
    }

    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      serviceRoleKey,
      { auth: { autoRefreshToken: false, persistSession: false } },
    )

    let onlyIssueId: string | null = null
    let onlyEvent: string | null = null
    try {
      const body = await req.json()
      onlyIssueId = body?.issue_id ?? body?.record?.issue_id ?? null
      onlyEvent = body?.event ?? body?.record?.event ?? null
    } catch {
      // drain mode
    }

    let query = supabaseClient
      .from('booking_issue_notifications')
      .select('id, issue_id, event, attempts')
      .eq('status', 'pending')
      .order('created_at', { ascending: true })
      .limit(BATCH_SIZE)

    if (onlyIssueId) query = query.eq('issue_id', onlyIssueId)
    if (onlyEvent) query = query.eq('event', onlyEvent)

    const { data: pending, error: pendingError } = await query
    if (pendingError) {
      return json({ error: 'Failed to read outbox', details: pendingError.message }, 500)
    }
    if (!pending || pending.length === 0) {
      return json({ success: true, processed: 0, sent: 0 })
    }

    let sent = 0
    let failed = 0

    for (const row of pending) {
      try {
        const { data: issue, error: issueError } = await supabaseClient
          .from('booking_issues')
          .select(
            'id, booking_id, building_id, reporter_profile_id, reporter_apartment_id, kind, status',
          )
          .eq('id', row.issue_id)
          .single()

        if (issueError || !issue) {
          throw new Error(`booking issue not found: ${issueError?.message ?? 'missing'}`)
        }

        const { data: booking, error: bookingError } = await supabaseClient
          .from('booking_requests')
          .select('id, borrower_apartment_id, lender_apartment_id')
          .eq('id', issue.booking_id)
          .single()

        if (bookingError || !booking) {
          throw new Error(`booking not found: ${bookingError?.message ?? 'missing'}`)
        }

        const recipientIds = new Set<string>()

        if (row.event === 'reported') {
          const { data: admins, error: adminError } = await supabaseClient
            .from('profiles')
            .select('id, receives_push_notifications, apartments!inner(building_id)')
            .eq('role', 'admin')
            .eq('status', 'approved')
            .eq('apartments.building_id', issue.building_id)
          if (adminError) throw new Error(`failed to resolve admins: ${adminError.message}`)
          for (const p of admins ?? []) {
            if (p.receives_push_notifications && p.id !== issue.reporter_profile_id) {
              recipientIds.add(p.id)
            }
          }

          const counterpartApartmentId =
            issue.reporter_apartment_id === booking.borrower_apartment_id
              ? booking.lender_apartment_id
              : booking.borrower_apartment_id

          const { data: counterpart, error: counterpartError } = await supabaseClient
            .from('profiles')
            .select('id, receives_push_notifications')
            .eq('apartment_id', counterpartApartmentId)
            .eq('status', 'approved')
          if (counterpartError) {
            throw new Error(`failed to resolve counterpart: ${counterpartError.message}`)
          }
          for (const p of counterpart ?? []) {
            if (p.receives_push_notifications && p.id !== issue.reporter_profile_id) {
              recipientIds.add(p.id)
            }
          }
        } else {
          const { data: reporters, error: reporterError } = await supabaseClient
            .from('profiles')
            .select('id, receives_push_notifications')
            .eq('apartment_id', issue.reporter_apartment_id)
            .eq('status', 'approved')
          if (reporterError) {
            throw new Error(`failed to resolve reporter apartment: ${reporterError.message}`)
          }
          for (const p of reporters ?? []) {
            if (p.receives_push_notifications) recipientIds.add(p.id)
          }
        }

        const kindLabel = KIND_LABEL[issue.kind as string] ?? 'booking issue'
        const title = row.event === 'reported'
          ? 'Booking issue reported'
          : issue.status === 'upheld'
            ? 'Booking issue upheld'
            : 'Booking issue dismissed'
        const body = row.event === 'reported'
          ? `A neighbor reported: ${kindLabel}.`
          : `Your report (${kindLabel}) was ${issue.status}.`

        for (const id of recipientIds) {
          await sendPushToUser(supabaseClient, id, title, body, {
            type: 'booking_issue',
            event: String(row.event),
            issue_id: String(issue.id),
            booking_id: String(issue.booking_id),
            kind: String(issue.kind),
          })
        }

        await supabaseClient
          .from('booking_issue_notifications')
          .update({
            status: 'sent',
            attempts: (row.attempts ?? 0) + 1,
            recipients: recipientIds.size,
            sent_at: new Date().toISOString(),
            last_error: null,
          })
          .eq('id', row.id)

        sent++
      } catch (e) {
        const attempts = (row.attempts ?? 0) + 1
        const message = (e as Error)?.message ?? String(e)
        console.error(`[notify-booking-issue] issue ${row.issue_id} failed: ${message}`)
        await supabaseClient
          .from('booking_issue_notifications')
          .update({
            status: attempts >= MAX_ATTEMPTS ? 'failed' : 'pending',
            attempts,
            last_error: message,
          })
          .eq('id', row.id)
        failed++
      }
    }

    return json({ success: true, processed: pending.length, sent, failed })
  } catch (error) {
    console.error('[notify-booking-issue] Unhandled error:', (error as Error)?.message ?? error)
    return json({ error: 'Internal server error', details: (error as Error)?.message ?? String(error) }, 500)
  }
})
