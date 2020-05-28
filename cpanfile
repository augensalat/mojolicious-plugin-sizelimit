if("$]" =~ m{^5.01[024]}) {
    # we handle Perl 5.10,5.12,5.14 separately, because only
    # certain versions of Mojolicious are compatible with it.
    requires 'Mojolicious', '== 8.02';
} elsif( $] >= 5.016 ) {
    # assume Perl >= 5.16 , then we want Mojolicious >= 8.02
    requires 'Mojolicious', '8.02';
}
