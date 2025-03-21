package main

import (
	ipc "libp2p_ipc"
	"testing"

	capnp "capnproto.org/go/capnp/v3"
	"github.com/go-errors/errors"
	peer "github.com/libp2p/go-libp2p-core/peer"
	pubsub "github.com/libp2p/go-libp2p-pubsub"
	"github.com/stretchr/testify/require"
)

type upcallTrap struct {
	Tag                   string
	PeerConnected         chan ipc.DaemonInterface_PeerConnected
	PeerDisconnected      chan ipc.DaemonInterface_PeerDisconnected
	IncomingStream        chan ipc.DaemonInterface_IncomingStream
	GossipReceived        chan ipc.DaemonInterface_GossipReceived
	StreamLost            chan ipc.DaemonInterface_StreamLost
	StreamComplete        chan ipc.DaemonInterface_StreamComplete
	StreamMessageReceived chan ipc.DaemonInterface_StreamMessageReceived
}

func newUpcallTrap(tag string, chanSize int) *upcallTrap {
	return &upcallTrap{
		Tag:                   tag,
		PeerConnected:         make(chan ipc.DaemonInterface_PeerConnected, chanSize),
		PeerDisconnected:      make(chan ipc.DaemonInterface_PeerDisconnected, chanSize),
		IncomingStream:        make(chan ipc.DaemonInterface_IncomingStream, chanSize),
		GossipReceived:        make(chan ipc.DaemonInterface_GossipReceived, chanSize),
		StreamLost:            make(chan ipc.DaemonInterface_StreamLost, chanSize),
		StreamComplete:        make(chan ipc.DaemonInterface_StreamComplete, chanSize),
		StreamMessageReceived: make(chan ipc.DaemonInterface_StreamMessageReceived, chanSize),
	}
}

func launchFeedUpcallTrap(t *testing.T, out chan *capnp.Message, trap *upcallTrap, done chan interface{}) chan error {
	errChan := make(chan error)
	go func() {
		errChan <- feedUpcallTrap(func(format string, args ...interface{}) {
			t.Logf(format, args...)
		}, out, trap, done)
	}()
	return errChan
}

func feedUpcallTrap(logf func(format string, args ...interface{}), out chan *capnp.Message, trap *upcallTrap, done chan interface{}) error {
	for {
		select {
		case <-done:
			return nil
		case rawMsg := <-out:
			imsg, err := ipc.ReadRootDaemonInterface_Message(rawMsg)
			if err != nil {
				return err
			}
			if !imsg.HasPushMessage() {
				return errors.New("Received message is not a push")
			}
			pmsg, err := imsg.PushMessage()
			if err != nil {
				return err
			}
			if pmsg.HasPeerConnected() {
				m, err := pmsg.PeerConnected()
				if err != nil {
					return err
				}
				trap.PeerConnected <- m
			} else if pmsg.HasPeerDisconnected() {
				m, err := pmsg.PeerDisconnected()
				if err != nil {
					return err
				}
				trap.PeerDisconnected <- m
			} else if pmsg.HasGossipReceived() {
				m, err := pmsg.GossipReceived()
				if err != nil {
					return err
				}
				trap.GossipReceived <- m
			} else if pmsg.HasIncomingStream() {
				m, err := pmsg.IncomingStream()
				if err != nil {
					return err
				}
				trap.IncomingStream <- m
			} else if pmsg.HasStreamLost() {
				logf("%s: Stream lost", trap.Tag)
				m, err := pmsg.StreamLost()
				if err != nil {
					return err
				}
				trap.StreamLost <- m
			} else if pmsg.HasStreamComplete() {
				logf("%s: Stream complete", trap.Tag)
				m, err := pmsg.StreamComplete()
				if err != nil {
					return err
				}
				trap.StreamComplete <- m
			} else if pmsg.HasStreamMessageReceived() {
				m, err := pmsg.StreamMessageReceived()
				if err != nil {
					return err
				}
				trap.StreamMessageReceived <- m
			}
		}
	}
}

func mkAppForUpcallTest(t *testing.T, tag string) (*upcallTrap, *app, uint16, peer.AddrInfo) {
	trap := newUpcallTrap(tag, 64)

	app, appPort := newTestApp(t, nil, false)
	app.NoMDNS = true
	app.NoDHT = true
	appInfos, err := addrInfos(app.P2p.Host)
	require.NoError(t, err)

	app.P2p.Pubsub, err = pubsub.NewGossipSub(app.Ctx, app.P2p.Host)
	require.NoError(t, err)

	beginAdvertisingSendAndCheck(t, app)

	info := appInfos[0]
	t.Logf("%s: %s", tag, info.ID.String())

	return trap, app, appPort, info
}

func TestUpcalls(t *testing.T) {
	newProtocol := "/mina/97"

	aTrap, alice, alicePort, aliceInfo := mkAppForUpcallTest(t, "alice")
	bTrap, bob, bobPort, bobInfo := mkAppForUpcallTest(t, "bob")
	cTrap, carol, carolPort, carolInfo := mkAppForUpcallTest(t, "carol")

	// Initiate stream handlers
	testAddStreamHandlerDo(t, newProtocol, alice, 10990)
	testAddStreamHandlerDo(t, newProtocol, bob, 10991)
	testAddStreamHandlerDo(t, newProtocol, carol, 10992)

	errChans := make([]chan error, 0, 3)
	withTimeoutAsync(t, func(done chan interface{}) {
		defer close(done)
		errChans = append(errChans, launchFeedUpcallTrap(t, alice.OutChan, aTrap, done))
		errChans = append(errChans, launchFeedUpcallTrap(t, bob.OutChan, bTrap, done))
		errChans = append(errChans, launchFeedUpcallTrap(t, carol.OutChan, cTrap, done))

		// subscribe
		topic := "testtopic"
		var subId uint64 = 123
		testSubscribeDo(t, alice, topic, subId, 11960)

		// Bob connects to Alice
		testAddPeerImplDo(t, bob, aliceInfo, true)
		t.Logf("peer connected: waiting bob <-> alice")
		checkPeerConnected(t, <-aTrap.PeerConnected, bobInfo)
		checkPeerConnected(t, <-bTrap.PeerConnected, aliceInfo)
		t.Logf("peer connected: performed bob <-> alice")

		// Alice initiates and then closes connection to Bob
		testStreamOpenSendClose(t, alice, alicePort, bob, bobPort, 11900, newProtocol, aTrap, bTrap)
		// Bob initiates and then closes connection to Alice
		testStreamOpenSendClose(t, bob, bobPort, alice, alicePort, 11910, newProtocol, bTrap, aTrap)

		// Bob connects to Carol
		testAddPeerImplDo(t, bob, carolInfo, true)
		t.Logf("peer connected: waiting bob <-> carol")
		checkPeerConnected(t, <-cTrap.PeerConnected, bobInfo)
		checkPeerConnected(t, <-bTrap.PeerConnected, carolInfo)
		t.Logf("peer connected: performed bob <-> carol")

		_ = carolPort
		select {
		case _ = <-aTrap.PeerConnected:
			t.Fatal("Peer connected to Alice (unexpectedly)")
		default:
		}
		// Bob initiates and then closes connection to Carol
		_, cStreamId1 := testStreamOpenSend(t, bob, bobPort, carol, carolPort, 11920, newProtocol, bTrap, cTrap)

		// Alice initiates and then resets connection to Bob
		testStreamOpenSendReset(t, alice, alicePort, bob, bobPort, 11930, newProtocol, aTrap, bTrap)
		// Bob initiates and then resets connection to Alice
		testStreamOpenSendReset(t, bob, bobPort, alice, alicePort, 11940, newProtocol, bTrap, aTrap)
		require.NoError(t, bob.P2p.Host.Close())
		for {
			t.Logf("awaiting disconnect from Alice ...")
			m := <-aTrap.PeerDisconnected
			pid := getPeerDisconnectedPeerId(t, m)
			if pid == peerId(carolInfo) {
				// Carol can connect to alice and even disconnect when Bob closes
				// Seems like a legit behaviour overall
			} else if pid == peerId(bobInfo) {
				break
			} else {
				t.Logf("Unexpected disconnect from peer id %s", pid)
			}
		}
		t.Logf("stream lost, carol: waiting")
		checkStreamLost(t, <-cTrap.StreamLost, cStreamId1, "read failure: stream reset")
		t.Logf("stream lost, carol: processed")

		testAddPeerImplDo(t, alice, carolInfo, true)
		testStreamOpenSendClose(t, carol, carolPort, alice, alicePort, 11950, newProtocol, cTrap, aTrap)

		msg := []byte("bla-bla")
		testPublishDo(t, carol, topic, msg, 11970)

		t.Logf("checkGossipReceived: waiting")
		checkGossipReceived(t, <-aTrap.GossipReceived, msg, subId, peerId(carolInfo))
	}, "test upcalls: some of upcalls didn't happen")
	for _, errChan := range errChans {
		if err := <-errChan; err != nil {
			t.Errorf("feedUpcallTrap failed with %s", err)
		}
	}
}

func checkGossipReceived(t *testing.T, m ipc.DaemonInterface_GossipReceived, msg []byte, subId uint64, senderPeerId string) {
	pi, err := m.Sender()
	require.NoError(t, err)
	actualPI, err := readPeerInfo(pi)
	require.NoError(t, err)
	require.Equal(t, senderPeerId, actualPI.PeerID)
	data, err := m.Data()
	require.NoError(t, err)
	subscriptionId, err := m.SubscriptionId()
	require.NoError(t, err)
	require.Equal(t, subId, subscriptionId.Id())
	require.Equal(t, msg, data)
}

func testStreamOpenSend(t *testing.T, appA *app, appAPort uint16, appB *app, appBPort uint16, rpcSeqno uint64, protocol string, aTrap *upcallTrap, bTrap *upcallTrap) (uint64, uint64) {
	aPeerId := appA.P2p.Host.ID().String()

	// Open a stream from A to B
	aStreamId := testOpenStreamDo(t, appA, appB.P2p.Host, appBPort, rpcSeqno, protocol)
	bStreamId := checkIncomingStream(t, <-bTrap.IncomingStream, aPeerId, protocol)

	// // Send a message from B to A
	// msg := []byte("msg")
	// testSendStreamDo(t, appB, bStreamId, msg, rpcSeqno+1)
	// checkStreamMessageReceived(t, <-aTrap.StreamMessageReceived, aStreamId, msg)

	return aStreamId, bStreamId
}
func testStreamOpenSendReset(t *testing.T, appA *app, appAPort uint16, appB *app, appBPort uint16, rpcSeqno uint64, protocol string, aTrap *upcallTrap, bTrap *upcallTrap) {
	aStreamId, bStreamId := testStreamOpenSend(t, appA, appAPort, appB, appBPort, rpcSeqno+1, protocol, aTrap, bTrap)
	// A closes the stream
	testResetStreamDo(t, appA, aStreamId, rpcSeqno)
	checkStreamLost(t, <-aTrap.StreamLost, aStreamId, "read failure: stream reset")
	checkStreamLost(t, <-bTrap.StreamLost, bStreamId, "read failure: stream reset")
}

func testStreamOpenSendClose(t *testing.T, appA *app, appAPort uint16, appB *app, appBPort uint16, rpcSeqno uint64, protocol string, aTrap *upcallTrap, bTrap *upcallTrap) {
	aPeerId := appA.P2p.Host.ID().String()

	// Open a stream from A to B
	aStreamId := testOpenStreamDo(t, appA, appB.P2p.Host, appBPort, rpcSeqno, protocol)
	bStreamId := checkIncomingStream(t, <-bTrap.IncomingStream, aPeerId, protocol)

	// Send a message from A to B
	msg1 := []byte("somedata")
	testSendStreamDo(t, appA, aStreamId, msg1, rpcSeqno+1)
	checkStreamMessageReceived(t, <-bTrap.StreamMessageReceived, bStreamId, msg1)

	// Send a message from A to B
	msg2 := []byte("otherdata")
	testSendStreamDo(t, appA, aStreamId, msg2, rpcSeqno+2)
	checkStreamMessageReceived(t, <-bTrap.StreamMessageReceived, bStreamId, msg2)

	// Send a message from B to A
	msg3 := []byte("reply")
	testSendStreamDo(t, appB, bStreamId, msg3, rpcSeqno+3)
	checkStreamMessageReceived(t, <-aTrap.StreamMessageReceived, aStreamId, msg3)

	// A closes the stream
	testCloseStreamDo(t, appA, aStreamId, rpcSeqno+4)
	checkStreamComplete(t, <-aTrap.StreamComplete, aStreamId)
	checkStreamComplete(t, <-bTrap.StreamComplete, bStreamId)
}

func peerId(info peer.AddrInfo) string {
	return info.ID.String()
}

func checkPeerConnected(t *testing.T, m ipc.DaemonInterface_PeerConnected, peerInfo peer.AddrInfo) {
	pid, err := m.PeerId()
	require.NoError(t, err)
	pid_, err := pid.Id()
	require.NoError(t, err)
	require.Equal(t, peerId(peerInfo), pid_)
}

func getPeerDisconnectedPeerId(t *testing.T, m ipc.DaemonInterface_PeerDisconnected) string {
	pid, err := m.PeerId()
	require.NoError(t, err)
	pid_, err := pid.Id()
	require.NoError(t, err)
	return pid_
}

func checkPeerDisconnected(t *testing.T, m ipc.DaemonInterface_PeerDisconnected, peerInfo peer.AddrInfo) {
	require.Equal(t, peerId(peerInfo), getPeerDisconnectedPeerId(t, m))
}

func checkIncomingStream(t *testing.T, m ipc.DaemonInterface_IncomingStream, expectedPeerId string, expectedProtocol string) uint64 {
	sid, err := m.StreamId()
	require.NoError(t, err)
	pi, err := m.Peer()
	require.NoError(t, err)
	actualPI, err := readPeerInfo(pi)
	require.NoError(t, err)
	protocol, err := m.Protocol()
	require.NoError(t, err)
	require.Equal(t, expectedPeerId, actualPI.PeerID)
	require.Equal(t, expectedProtocol, protocol)
	return sid.Id()
}

func checkStreamMessageReceived(t *testing.T, m ipc.DaemonInterface_StreamMessageReceived, expectedStreamId uint64, expectedData []byte) {
	sm, err := m.Msg()
	require.NoError(t, err)
	sid, err := sm.StreamId()
	require.NoError(t, err)
	data, err := sm.Data()
	require.NoError(t, err)
	require.Equal(t, expectedStreamId, sid.Id())
	require.Equal(t, expectedData, data)
}

func checkStreamLost(t *testing.T, m ipc.DaemonInterface_StreamLost, expectedStreamId uint64, expectedReason string) {
	sid, err := m.StreamId()
	require.NoError(t, err)
	require.Equal(t, expectedStreamId, sid.Id())
	reason, err := m.Reason()
	require.NoError(t, err)
	require.Equal(t, expectedReason, reason)
}

func checkStreamComplete(t *testing.T, m ipc.DaemonInterface_StreamComplete, expectedStreamId uint64) {
	sid, err := m.StreamId()
	require.NoError(t, err)
	require.Equal(t, expectedStreamId, sid.Id())
}
