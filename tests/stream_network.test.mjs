import test from 'node:test'
import assert from 'node:assert/strict'
import { networkStatus, privateIPv4 } from '../scripts/stream_network.js'

test('only a selected direct private host candidate reports LAN', () => {
    const report = new Map([['t', { type: 'transport', selectedCandidatePairId: 'p' }], ['p', { remoteCandidateId: 'r', localCandidateId: 'l', currentRoundTripTime: .004 }], ['r', { candidateType: 'host', address: '192.168.1.178' }], ['l', { candidateType: 'host', address: '192.168.1.50' }]])
    assert.equal(networkStatus(report), 'LAN connected · 4 ms RTT')
    report.get('r').candidateType = 'relay'
    assert.equal(networkStatus(report), 'Video uses a relay · 4 ms RTT')
    report.get('r').candidateType = 'host'; report.get('r').address = '100.72.220.117'
    assert.equal(networkStatus(report), 'Direct video connection · 4 ms RTT')
    report.get('r').address = 'private-host.local'
    assert.equal(networkStatus(report), 'Direct video connection · 4 ms RTT')
    assert.equal(networkStatus(new Map()), 'Checking video connection')
})
test('private address recognition rejects malformed and public addresses', () => {
    for (const value of ['10.0.0.2', '172.16.0.2', '192.168.1.178']) assert.equal(privateIPv4(value), true)
    for (const value of ['172.32.0.2', '127.0.0.1', '192.168.1.999', '192.168..1', '']) assert.equal(privateIPv4(value), false)
})
