"""Explicit release coverage; every case measures speech over a real connection."""


def scenarios(mode, seconds):
    def case(name, **changes):
        return dict(id=name, codec='mpeg4AACELD', format='mono48k', bitRate=48000,
                    profile='echoCancelledInput', speaker=False, vad='standard', transmitIsolation=True,
                    masterIsolation=False, peerIsolation=False, duck=True,
                    masterVolume=1.0, peerVolume=1.0, localMute=False, outputMute=False,
                    seconds=seconds) | changes
    default = case('default')
    if mode == 'smoke':
        return [default]
    if mode == 'identity':
        # Both bundled pairs complete at least one full utterance per recording.
        duration = max(20, seconds)
        return [case('identity-default', seconds=duration),
                case('identity-pcm16', codec='pcm16', transmitIsolation=False, seconds=duration),
                case('identity-opus', codec='opus', transmitIsolation=False, seconds=duration)]
    quick = [default,
        case('opus-24k-effects', codec='opus', format='mono24k', profile='standard',
             vad='lowNoise', transmitIsolation=False, masterIsolation=True, duck=False,
             masterVolume=0.5, peerVolume=0.5),
        case('pcm16-16k-voicechat', codec='pcm16', format='mono16k', profile='voiceChat',
             vad='noisy', peerIsolation=True),
        case('output-mute', codec='pcm16', format='mono16k', profile='voiceChat',
             outputMute=True, seconds=2),
        case('output-recovery', codec='pcm16', format='mono16k', profile='voiceChat', speaker=True)]
    if mode == 'quick':
        return quick
    full = [case(f'{codec}-{rate}', codec=codec, format=rate)
            for codec in ['pcm16', 'opus', 'mpeg4AACELD']
            for rate in ['mono16k', 'mono24k', 'mono48k']]
    full += [case(f'opus-{rate}-bitrate-{bitrate}', codec='opus', format=rate, bitRate=bitrate)
             for rate in ['mono16k', 'mono24k', 'mono48k'] for bitrate in ((16000 if rate == 'mono16k' else 24000), 128000)]
    full += [case(f'AAC-{rate}-bitrate-{bitrate}', codec='mpeg4AACELD', format=rate, bitRate=bitrate)
             for rate, limits in [('mono16k', (48000, 48000)), ('mono24k', (32000, 64000)),
                                  ('mono48k', (48000, 128000))] for bitrate in sorted(set(limits))]
    full += quick[1:]
    full += [case('speaker', profile='speakerDefault', masterVolume=2.0),
             case('speaker-without-explicit-echo', profile='standard', speaker=True),
             case('master-zero', masterVolume=0.0, seconds=2), case('master-recovery'),
             case('peer-zero', peerVolume=0.0, seconds=2), case('peer-recovery'),
             case('local-mute', localMute=True, seconds=2), case('local-recovery')]
    return full
