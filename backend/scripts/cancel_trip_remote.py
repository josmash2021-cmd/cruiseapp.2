import asyncio
import asyncpg

async def main():
    conn = await asyncpg.connect('postgresql://postgres:AxvxsqdWOwNorUnWJdXrqaJuLoomhkmI@postgres.railway.internal:5432/railway')
    
    rows = await conn.fetch("""
        SELECT id, status, rider_id, driver_id, pickup_address, dropoff_address, created_at
        FROM trips
        WHERE status IN ('requested', 'accepted', 'driver_en_route', 'arrived', 'in_trip')
        ORDER BY created_at DESC
        LIMIT 5
    """)
    
    print('=== VIAJES ACTIVOS ===')
    print('Found: %d trips' % len(rows))
    for r in rows:
        print('ID: %s, Status: %s, Rider: %s, Driver: %s' % (r['id'], r['status'], r['rider_id'], r['driver_id']))
        print('  From: %s' % r['pickup_address'])
        print('  To: %s' % r['dropoff_address'])
        print('  Created: %s' % r['created_at'])
        print()
    
    if not rows:
        print('No hay viajes activos.')
        await conn.close()
        return
    
    trip_id = rows[0]['id']
    print('Cancelando viaje ID: %s' % trip_id)
    
    await conn.execute("""
        UPDATE trips 
        SET status = 'cancelled', 
            cancellation_reason = 'Cancelled by admin via script',
            cancelled_at = NOW()
        WHERE id = $1
    """, trip_id)
    
    print('Viaje %s cancelado exitosamente.' % trip_id)
    await conn.close()

asyncio.run(main())
