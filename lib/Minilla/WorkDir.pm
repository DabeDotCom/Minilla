package Minilla::WorkDir;
use strict;
use warnings;
use utf8;
use Path::Tiny;
use Archive::Tar;
use File::pushd;
use Data::Dumper; # serializer
use File::Spec::Functions qw(splitdir);
use File::Basename qw(dirname);

use Minilla::Util qw(randstr);
use Minilla::FileGatherer;
use Minilla::ReleaseTest;

use Moo;

has project => (
    is => 'ro',
    required => 1,
);

has dir => (
    is => 'lazy',
);

has c => (
    is       => 'ro',
    required => 1,
);

has files => (
    is => 'lazy',
);

has [qw(prereq_specs)] => (
    is => 'lazy',
);

no Moo;

{
    our $INSTANCE;
    sub instance {
        my ($class, $c) = @_;
        my $project = Minilla::Project->new(
            c => $c,
        );
        $INSTANCE ||= Minilla::WorkDir->new(
            project => $project,
            c => $c,
        );
    }
}

sub DEMOLISH {
    my $self = shift;
    unless ($self->c->debug) {
        path(path($self->dir)->dirname)->remove_tree({safe => 0});
    }
}

sub _build_dir {
    my $self = shift;
    my $dirname = $^O eq 'MSWin32' ? '_build' : '.build';
    path($self->project->dir, $dirname, randstr(8));
}

sub _build_prereq_specs {
    my $self = shift;

    my $cpanfile = Module::CPANfile->load(path($self->project->dir, 'cpanfile'));
    return $cpanfile->prereq_specs;
}

sub _build_files {
    my $self = shift;

    my @files = Minilla::FileGatherer->gather_files(
        $self->project->dir
    );
    \@files;
}

sub as_string {
    my $self = shift;
    $self->dir;
}

sub BUILD {
    my ($self) = @_;

    $self->c->infof("Creating working directory: %s\n", $self->dir);

    # copying
    path($self->dir)->mkpath;
    for my $src (@{$self->files}) {
        next if -d $src;
        $self->c->infof("Copying %s\n", $src);
        my $dst = path($self->dir, path($src)->relative($self->project->dir));
        path($dst->dirname)->mkpath;
        path($src)->copy($dst);
    }
}

sub build {
    my ($self) = @_;

    return if $self->{build}++;

    my $guard = pushd($self->dir);

    # Generate meta file
    {
        my $meta = $self->project->cpan_meta('stable');
        $meta->save('META.yml', {
            version => 1.4,
        });
        $meta->save('META.json', {
            version => 2.0,
        });
    }

    my @files = @{$self->files};

    $self->c->infof("Writing MANIFEST file\n");
    {
        path('MANIFEST')->spew(join("\n", @files));
    }

    Minilla::ReleaseTest->write_release_tests($self->project, $self->dir);
}

sub dist_test {
    my $self = shift;

    $self->build();

    $self->project->verify_prereqs([qw(runtime)], $_) for qw(requires recommends);
    $self->project->verify_prereqs([qw(test)], $_) for qw(requires recommends);

    {
        my $guard = pushd($self->dir);
        $self->c->cmd('prove', '-r', '-l', 't', (-d 'xt' ? 'xt' : ()));
    }
}

sub dist {
    my ($self) = @_;

    $self->{tarball} ||= do {
        my $c = $self->c;

        $self->build();

        my $guard = pushd($self->dir);

        # Create tar ball
        my $tarball = sprintf('%s-%s.tar.gz', $self->project->dist_name, $self->project->version);

        my $tar = Archive::Tar->new;
        for (@{$self->files}, qw(Build.PL LICENSE META.json META.yml MANIFEST)) {
            $tar->add_data(path($self->project->dist_name . '-' . $self->project->version, $_), path($_)->slurp);
        }
        $tar->write(path($tarball), COMPRESS_GZIP);
        $self->c->infof("Wrote %s\n", $tarball);

        path($tarball)->absolute;
    };
}

1;