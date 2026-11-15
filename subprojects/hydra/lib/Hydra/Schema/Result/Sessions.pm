use utf8;
package Hydra::Schema::Result::Sessions;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::Sessions

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<Hydra::Component::ToJSON>

=back

=cut

__PACKAGE__->load_components("+Hydra::Component::ToJSON");

=head1 TABLE: C<sessions>

=cut

__PACKAGE__->table("sessions");

=head1 ACCESSORS

=head2 id

  data_type: 'text'
  is_nullable: 0

=head2 data

  data_type: 'jsonb'
  is_nullable: 1

=head2 expires

  data_type: 'bigint'
  default_value: 0
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "text", is_nullable => 0 },
  "data",
  { data_type => "jsonb", is_nullable => 1 },
  "expires",
  { data_type => "bigint", default_value => 0, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");


# Created by DBIx::Class::Schema::Loader v0.07051 @ 2026-11-15 20:11:08
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:QldCxHRoOPRSwROM1QcVuQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
