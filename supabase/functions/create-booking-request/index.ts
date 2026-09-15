// Pinned npm: specifier + Deno.serve keep us off esm.sh / deno.land/std,
// both of which have flaked during deploys (esm.sh 522, deno.land outages).
import { createClient } from 'npm:@supabase/supabase-js@2.45.4'
import { sendPushToUser } from '../_shared/push.ts'
import { captureException } from '../_shared/sentry.ts'

const serve = Deno.serve

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // Create Supabase client with service role key to bypass RLS
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      {
        auth: {
          autoRefreshToken: false,
          persistSession: false
        }
      }
    )

    // Get the authorization header
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Missing authorization header' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Get the user from the token
    const token = authHeader.replace('Bearer ', '')
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser(token)
    
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: 'Invalid or expired token' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Parse request body
    const { spot_id, start_time, end_time } = await req.json()

    if (!spot_id || !start_time || !end_time) {
      return new Response(
        JSON.stringify({ error: 'spot_id, start_time, and end_time are required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Validate time range
    const start = new Date(start_time)
    const end = new Date(end_time)
    
    if (isNaN(start.getTime()) || isNaN(end.getTime())) {
      return new Response(
        JSON.stringify({ error: 'Invalid date format' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    if (end <= start) {
      return new Response(
        JSON.stringify({ error: 'end_time must be after start_time' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Get borrower profile — must have an apartment and be approved.
    const { data: borrowerProfile, error: borrowerError } = await supabaseClient
      .from('profiles')
      .select('id, apartment_id, status, apartments(building_id)')
      .eq('id', user.id)
      .single()

    if (borrowerError || !borrowerProfile) {
      return new Response(
        JSON.stringify({ error: 'Borrower profile not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    if (!borrowerProfile.apartment_id || borrowerProfile.status !== 'approved') {
      return new Response(
        JSON.stringify({ error: 'Borrower must be an approved member of a building' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const borrowerBuildingId = (borrowerProfile.apartments as any)?.building_id

    // Get parking spot with its apartment info.
    const { data: spot, error: spotError } = await supabaseClient
      .from('parking_spots')
      .select('id, apartment_id, building_id, is_active, apartments(building_id)')
      .eq('id', spot_id)
      .single()

    if (spotError || !spot) {
      return new Response(
        JSON.stringify({ error: 'Parking spot not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Verify spot is active.
    if (!spot.is_active) {
      return new Response(
        JSON.stringify({ error: 'Parking spot is not active' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Verify borrower and spot are in the same building.
    const spotBuildingId = spot.building_id ?? (spot.apartments as any)?.building_id
    if (spotBuildingId !== borrowerBuildingId) {
      return new Response(
        JSON.stringify({ error: 'Borrower and spot must be in the same building' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Prevent self-booking (same apartment).
    if (spot.apartment_id === borrowerProfile.apartment_id) {
      return new Response(
        JSON.stringify({ error: 'Cannot request your own apartment\'s parking spot' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Recurring templates expand in SQL (migration 046). Zero periods ⇒
    // always available (backward compatible). Overlap, not containment —
    // same rule as ParkingSpotService.isSpotAvailable.
    const { data: covered, error: coverError } = await supabaseClient.rpc(
      'spot_availability_overlaps',
      { p_spot_id: spot_id, p_start: start_time, p_end: end_time },
    )
    if (coverError) {
      console.error('[create-booking-request] spot_availability_overlaps failed:', coverError.message)
      return new Response(
        JSON.stringify({ error: 'Failed to validate availability', details: coverError.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }
    if (covered !== true) {
      return new Response(
        JSON.stringify({ error: 'Requested window is not within the spot\'s availability' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Find a representative profile in the lender apartment to receive the push notification.
    // Prefer apartment admins; fall back to any approved member.
    const { data: lenderProfiles } = await supabaseClient
      .from('profiles')
      .select('id, is_apartment_admin, receives_push_notifications')
      .eq('apartment_id', spot.apartment_id)
      .eq('status', 'approved')

    const lenderPushRecipient = lenderProfiles?.find(
      (p: any) => p.is_apartment_admin && p.receives_push_notifications
    ) ?? lenderProfiles?.find(
      (p: any) => p.receives_push_notifications
    ) ?? lenderProfiles?.[0]

    // Create booking request with apartment-scoped parties.
    const { data: bookingRequest, error: insertError } = await supabaseClient
      .from('booking_requests')
      .insert({
        spot_id: spot_id,
        borrower_apartment_id: borrowerProfile.apartment_id,
        lender_apartment_id: spot.apartment_id,
        created_by_profile_id: user.id,
        start_time: start_time,
        end_time: end_time,
        status: 'pending'
      })
      .select()
      .single()

    if (insertError) {
      console.error('[create-booking-request] DB insert error:', insertError.message, insertError.details ?? '', insertError.hint ?? '')
      return new Response(
        JSON.stringify({ error: 'Failed to create booking request', details: insertError.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    if (lenderPushRecipient && bookingRequest?.id != null) {
      try {
        await sendPushToUser(
          supabaseClient,
          lenderPushRecipient.id,
          'New booking request',
          'Someone requested your parking spot.',
          { booking_id: String(bookingRequest.id), type: 'booking_request' }
        )
      } catch (pushError) {
        // Push failures are non-fatal — the booking was already created successfully.
        console.error('[create-booking-request] Push notification failed:', pushError?.message ?? pushError)
      }
    }

    return new Response(
      JSON.stringify({ 
        success: true,
        booking: bookingRequest
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    console.error('[create-booking-request] Unhandled error:', error?.message ?? error, error?.stack ?? '')
    await captureException(error, { functionName: 'create-booking-request' })
    return new Response(
      JSON.stringify({ error: 'Internal server error', details: error?.message ?? String(error) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})

