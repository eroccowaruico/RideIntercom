"""Explicit release coverage; every case measures speech over a real connection."""


def scenarios(mode, seconds):
    def case(name, **changes):
        return dict(id=name, codec='mpeg4AACELDv2', format='mono48k', bitRate=32000,
                    profile='echoCancelledInput', speaker=False, vad='standard', transmitIsolation=True,
                    masterIsolation=False, peerIsolation=False, duck=True,
                    masterVolume=1.0, peerVolume=1.0, localMute=False, outputMute=False,
                    seconds=seconds) | changes
    default = case('default')
    if mode == 'smoke':
        return [default]
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
            for codec in ['pcm16', 'opus', 'mpeg4AACELDv2']
            for rate in ['mono16k', 'mono24k', 'mono48k']]
    full += [case(f'{codec}-{rate}-bitrate-{bitrate}', codec=codec, format=rate, bitRate=bitrate)
             for codec, limits in [('opus', (6000, 128000)), ('mpeg4AACELDv2', (12000, 128000))]
             for rate in ['mono16k', 'mono24k', 'mono48k'] for bitrate in limits]
    full += quick[1:]
    full += [case('speaker', profile='speakerDefault', masterVolume=2.0),
             case('speaker-without-explicit-echo', profile='standard', speaker=True),
             case('master-zero', masterVolume=0.0, seconds=2), case('master-recovery'),
             case('peer-zero', peerVolume=0.0, seconds=2), case('peer-recovery'),
             case('local-mute', localMute=True, seconds=2), case('local-recovery')]
    return full
