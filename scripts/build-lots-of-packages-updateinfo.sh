echo '<?xml version="1.0"?>'
echo '<updates>'

ver='0.1'
ver_new='0.2'
rel='50'
arch='x86_64'

i=1
for f in $( ls *.rpm | grep "foo[0-9]\+-$ver-$rel\.$arch\.rpm" ); do
    name=$( echo "$f" | cut -d '-' -f 1 )

echo "<update from='katello-qa-list@redhat.com' status='stable' type='security' version='1'>
  <id>RHBA-2018:$( printf '%04d' $i )</id>
  <title>Foo$i erratum title</title>
  <release>1</release>
  <issued date='$( date +'%Y-%m-%d %H:%M:%S' )'/>
  <description>Foo$i erratum description</description>
  <severity>critical</severity>
  <pkglist>
    <collection short=''>
      <name>1</name>
      <package arch='$arch' name='$name' release='$rel' src='http://www.fedoraproject.org' version='$ver_new'>
        <filename>$name-$ver_new-$rel.$arch.rpm</filename>
      </package>
      <package arch='$arch' name='$name-sub0' release='$rel' src='http://www.fedoraproject.org' version='$ver_new'>
        <filename>$name-sub0-$ver_new-$rel.$arch.rpm</filename>
      </package>
    </collection>
  </pkglist>
</update>"

    let i+=1
    break
done

echo '</updates>'
